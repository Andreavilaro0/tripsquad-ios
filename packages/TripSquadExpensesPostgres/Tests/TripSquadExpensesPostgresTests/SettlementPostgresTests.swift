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

    /// G4 (bead 8hn) — invariante de concurrencia con DB real: N `crear` del MISMO
    /// settlement EN PARALELO → exactamente 1 fila, 1 `.creado`, resto `.duplicado`.
    /// Cubre el escenario que el criterio del P0 pedía y que solo estaba testeado en
    /// secuencial (`crearEsIdempotentePorClaveNatural`). El `ON CONFLICT DO NOTHING`
    /// sobre la clave natural lo hace determinista: un INSERT gana el `RETURNING`, el
    /// resto cae al `SELECT` de la fila existente.
    @Test func crearConcurrenteMismoSettlementDejaUnaSolaFila() async throws {
        try await conBD { repo, tripId in
            let s = Settlement(settlementId: "s-concurrente", tripId: tripId, from: ivan, to: ana,
                               transferIndex: 0, amountMinor: 2000, createdBy: ivan,
                               expiresAt: Date().addingTimeInterval(3600))
            let n = 8
            var resultados: [ResultadoSettle] = []
            try await withThrowingTaskGroup(of: ResultadoSettle.self) { group in
                for _ in 0..<n { group.addTask { try await repo.crear(s) } }
                for try await r in group { resultados.append(r) }
            }
            let creados = resultados.filter { if case .creado = $0 { return true }; return false }
            let duplicados = resultados.filter { if case .duplicado = $0 { return true }; return false }
            #expect(creados.count == 1, "exactamente un .creado bajo N inserts concurrentes")
            #expect(duplicados.count == n - 1, "el resto deben ser .duplicado")
            // Todos apuntan a la MISMA fila ganadora.
            guard case .creado(let idCreado) = creados.first else { Issue.record("falta .creado"); return }
            for case .duplicado(let idDup) in resultados {
                #expect(idDup == idCreado, "el duplicado devuelve el id de la fila ganadora")
            }
            // Una sola fila viva, verificada por la API pública (sin SQL crudo ni tocar `conBD`).
            let vivos = try await repo.pendientes(de: tripId, limit: 200, ahora: Date())
            #expect(vivos.count == 1, "una sola liquidación materializada")
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

            let completa = try await repo.pendientes(de: tripId, limit: 200, ahora: Date()).map(\.0)
            #expect(completa.count == 5)
            #expect(try await repo.pendientes(de: tripId, limit: 200, ahora: Date()).map(\.0) == completa)   // repetible
            let pagina = try await repo.pendientes(de: tripId, limit: 2, ahora: Date()).map(\.0)
            #expect(pagina == Array(completa.prefix(2)))                                      // prefijo, no azar
        }
    }

    /// Bot GitHub P2: la caducidad se filtra EN SQL, antes del `LIMIT`, para que los
    /// pending caducados no consuman la página y oculten los activos más nuevos.
    @Test func pendientesExcluyeCaducadosAntesDelLimit() async throws {
        try await conBD { repo, tripId in
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            // Dos pending que YA caducaron (expiresAt en el pasado respecto a `ahora`).
            for i in 0..<2 {
                let s = Settlement(settlementId: "cad-\(i)", tripId: tripId, from: ivan, to: ana,
                                   transferIndex: i, amountMinor: 1000, createdBy: ivan,
                                   expiresAt: base)   // caduca en `base`
                guard case .creado = try await repo.crear(s) else { Issue.record("esperaba .creado"); return }
            }
            // Uno activo (caduca mucho después).
            let activo = Settlement(settlementId: "activo", tripId: tripId, from: ivan, to: ana,
                                    transferIndex: 9, amountMinor: 1000, createdBy: ivan,
                                    expiresAt: base.addingTimeInterval(100 * 24 * 3600))
            guard case .creado = try await repo.crear(activo) else { Issue.record("esperaba .creado"); return }

            // Consulta DESPUÉS de que caduquen los dos, con limit=2 (los caducados lo
            // consumirían si el filtro fuese en Swift tras el LIMIT).
            let ahora = base.addingTimeInterval(24 * 3600)
            let pagina = try await repo.pendientes(de: tripId, limit: 2, ahora: ahora)
            #expect(pagina.count == 1)
            #expect(pagina.first?.1.settlementId == "activo")
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
