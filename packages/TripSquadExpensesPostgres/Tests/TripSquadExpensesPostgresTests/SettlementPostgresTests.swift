// Tests de integración del adaptador Postgres del flujo de confirmación de :settle
// (ADR-0017), contra una BD real. Se saltan si `PG_TEST` no está a "1" (local sin
// Docker); el CI la levanta como service container, aplica las migraciones de db/ y
// corre estos tests con PG_TEST=1. Mismo patrón que RepositorioPostgresTests.

import Foundation
import Testing
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadExpensesPostgres

@Suite("Adaptador Postgres — confirmación de settle (integración)", .enabled(if: pgHabilitado))
struct SettlementPostgresTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan")

    /// Levanta un cliente, siembra un viaje único con Ana e Iván, corre el cuerpo.
    /// Calca `RepositorioPostgresTests.conRepo`.
    func conBD(_ body: (RepositorioPostgres, String) async throws -> Void) async throws {
        let host = ProcessInfo.processInfo.environment["PG_TEST_HOST"] ?? "localhost"
        let config = PostgresClient.Configuration(
            host: host, port: 5432, username: "postgres", password: "postgres",
            database: "tripsquad", tls: .disable)
        let client = PostgresClient(configuration: config)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let repo = RepositorioPostgres(client: client)
            let trip = "trip-" + UUID().uuidString.prefix(8)
            try await client.query("INSERT INTO trips (id, currency_reference) VALUES (\(trip), 'EUR')")
            try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(trip), \(ana.raw))")
            try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(trip), \(ivan.raw))")
            try await body(repo, trip)
            group.cancelAll()
        }
    }

    @Test func crearEsIdempotentePorClaveNatural() async throws {
        try await conBD { repo, tripId in
            let s = Settlement(settlementId: "s1", tripId: tripId, from: ivan, to: ana,
                               transferIndex: 0, amountMinor: 2000, createdBy: ivan,
                               expiresAt: Date().addingTimeInterval(3600))
            guard case .creado = try await repo.crear(s) else { Issue.record("1a vez debe crear"); return }
            guard case .duplicado = try await repo.crear(s) else { Issue.record("2a vez debe deduplicar"); return }
        }
    }

    @Test func confirmarSoloContraparteYCuentaSaldos() async throws {
        try await conBD { repo, tripId in
            let s = Settlement(settlementId: "s2", tripId: tripId, from: ivan, to: ana,
                               transferIndex: 0, amountMinor: 2000, createdBy: ivan,
                               expiresAt: Date().addingTimeInterval(3600))
            guard case .creado(let id) = try await repo.crear(s) else {
                Issue.record("crear debía devolver .creado"); return
            }
            #expect(try await repo.confirmados(de: tripId).isEmpty)
            #expect(try await repo.transicionar(id: id, en: tripId, a: .confirmed, por: ana,
                                                ahora: Date(), rejectReason: nil) == .ok)
            #expect(try await repo.confirmados(de: tripId).count == 1)
        }
    }

    // MARK: - Tope + orden estable

    private func sembrarPendientes(_ repo: RepositorioPostgres, _ tripId: String, _ n: Int) async throws -> [String] {
        var ids: [String] = []
        for i in 0..<n {
            let s = Settlement(settlementId: "s-orden-\(i)", tripId: tripId, from: ivan, to: ana,
                               transferIndex: i, amountMinor: 1000, createdBy: ivan,
                               expiresAt: Date().addingTimeInterval(3600))
            guard case .creado(let id) = try await repo.crear(s) else { Issue.record("esperaba .creado"); break }
            ids.append(id)
        }
        return ids
    }

    /// `pendientes` respeta el `LIMIT` y devuelve el MISMO prefijo entre llamadas.
    /// Sin el `ORDER BY created_at, id` que se acaba de añadir, Postgres devolvía el
    /// orden físico del heap y la "página" era una lotería.
    @Test func pendientesRespetaElLimitYTieneOrdenEstable() async throws {
        try await conBD { repo, tripId in
            _ = try await sembrarPendientes(repo, tripId, 5)

            let completa = try await repo.pendientes(de: tripId, limit: 200).map(\.0)
            #expect(completa.count == 5)
            #expect(try await repo.pendientes(de: tripId, limit: 200).map(\.0) == completa)   // repetible
            let pagina = try await repo.pendientes(de: tripId, limit: 2).map(\.0)
            #expect(pagina == Array(completa.prefix(2)))                                      // prefijo, no azar
        }
    }

    /// `confirmados` NO lleva tope (alimenta los saldos): aunque haya muchos, salen
    /// todos — y en orden estable.
    @Test func confirmadosNoSeTruncaYVaOrdenado() async throws {
        try await conBD { repo, tripId in
            let ids = try await sembrarPendientes(repo, tripId, 5)
            for id in ids {
                #expect(try await repo.transicionar(id: id, en: tripId, a: .confirmed, por: ana,
                                                    ahora: Date(), rejectReason: nil) == .ok)
            }
            let confirmados = try await repo.confirmados(de: tripId)
            #expect(confirmados.count == 5, "confirmados no debe truncarse: son la entrada de los saldos")
            let repetida = try await repo.confirmados(de: tripId)
            #expect(confirmados.map(\.settlementId) == repetida.map(\.settlementId))   // orden repetible
        }
    }
}
