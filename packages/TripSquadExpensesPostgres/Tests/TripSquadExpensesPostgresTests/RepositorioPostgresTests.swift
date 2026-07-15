// Tests de integración del adaptador Postgres, contra una BD real. Se saltan si
// `PG_TEST` no está a "1" (local sin Docker); el CI la levanta como service
// container, aplica las migraciones de db/ y corre estos tests con PG_TEST=1.
//
// Mismos escenarios que el adaptador en memoria, ahora contra Postgres de verdad:
// idempotencia por (actor,key), dedupe estructural, tombstone-no-resucita, conflicto
// por ETag.

import Foundation
import Testing
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadExpensesPostgres

let pgHabilitado = ProcessInfo.processInfo.environment["PG_TEST"] == "1"

@Suite("Adaptador Postgres (integración)", .enabled(if: pgHabilitado))
struct RepositorioPostgresTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan")

    /// Levanta un cliente, siembra un viaje único con Ana e Iván, corre el cuerpo.
    func conRepo(_ body: (RepositorioPostgres, String) async throws -> Void) async throws {
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

    /// Id único por gasto: `expenses.id` es PK GLOBAL (los ids son UUID de cliente),
    /// así que no se pueden reusar entre tests que corren en paralelo.
    func nuevoId() -> String { "g-" + UUID().uuidString }

    func gasto(_ id: String, importe: Int64 = 3000) -> Gasto {
        Gasto(id: id, pagadoPor: ana, importeMinor: importe, reparto: .igual(entre: [ana, ivan]))
    }

    @Test func crearYLeer() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            let r = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "k1")
            guard case .creado = r else { Issue.record("esperaba creado, obtuve \(r)"); return }
            let leidos = try await repo.gastos(de: trip)
            #expect(leidos.count == 1)
            #expect(leidos.first?.gasto.importeMinor == 3000)
        }
    }

    @Test func idempotenciaPorClave() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            _ = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "k1")
            let previa = try await repo.respuestaPrevia(actor: ana, idempotencyKey: "k1")
            guard case .reproducido = previa else { Issue.record("esperaba replay, obtuve \(String(describing: previa))"); return }
            #expect(try await repo.gastos(de: trip).count == 1)
        }
    }

    @Test func dedupeEstructural() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            _ = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "k1")
            // Mismo id, otra clave, otro actor -> no duplica.
            let segundo = try await repo.guardar(gasto(id), en: trip, por: ivan, idempotencyKey: "k2")
            guard case .reproducido = segundo else { Issue.record("esperaba reproducido, obtuve \(segundo)"); return }
            #expect(try await repo.gastos(de: trip).count == 1)
        }
    }

    @Test func conflictoPorEtagRancio() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            _ = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "k1")
            let etagViejo = try #require(await repo.gasto(id: id, en: trip)).etag
            _ = try await repo.actualizar(gasto(id, importe: 4000), en: trip, por: ana, ifMatch: etagViejo, idempotencyKey: "k2")
            let r = try await repo.actualizar(gasto(id, importe: 9000), en: trip, por: ivan, ifMatch: etagViejo, idempotencyKey: "k3")
            guard case .conflicto = r else { Issue.record("esperaba conflicto, obtuve \(r)"); return }
        }
    }

    @Test func tombstoneNoResucita() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            _ = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "k1")
            let etag = try #require(await repo.gasto(id: id, en: trip)).etag
            _ = try await repo.eliminar(id: id, en: trip, por: ana, ifMatch: etag, idempotencyKey: "k2")
            let recreacion = try await repo.guardar(gasto(id), en: trip, por: ivan, idempotencyKey: "k3")
            #expect(recreacion == .rechazado(razon: "deleted"))
            #expect(try await repo.gastos(de: trip).isEmpty)
        }
    }

    @Test func repartoExactoVaATablaTipada() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            let exacto = Gasto(id: id, pagadoPor: ana, importeMinor: 1000,
                               reparto: .exacto([ana: 600, ivan: 400]))
            _ = try await repo.guardar(exacto, en: trip, por: ana, idempotencyKey: "k1")
            let leido = try #require(await repo.gasto(id: id, en: trip))
            guard case .exacto(let cuotas) = leido.gasto.reparto else {
                Issue.record("esperaba reparto exacto"); return
            }
            #expect(cuotas[ana] == 600)
            #expect(cuotas[ivan] == 400)
        }
    }

    /// (Codex P2) Al editar de reparto EXACTO a igual, las shares tipadas se limpian.
    @Test func editarDeExactoAIgualLimpiaShares() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            let exacto = Gasto(id: id, pagadoPor: ana, importeMinor: 1000, reparto: .exacto([ana: 600, ivan: 400]))
            _ = try await repo.guardar(exacto, en: trip, por: ana, idempotencyKey: "k1")
            let etag = try #require(await repo.gasto(id: id, en: trip)).etag
            // Editar a reparto igual.
            _ = try await repo.actualizar(gasto(id, importe: 1000), en: trip, por: ana, ifMatch: etag, idempotencyKey: "k2")
            let leido = try #require(await repo.gasto(id: id, en: trip))
            guard case .igual = leido.gasto.reparto else {
                Issue.record("esperaba reparto igual tras editar, obtuve \(leido.gasto.reparto)"); return
            }
            // Y las shares del exacto ya no cuelgan (leerShares interno vacío).
            let shares = try await repo.leerShares(id: id)
            #expect(shares.isEmpty, "las shares del reparto exacto deberían haberse limpiado")
        }
    }
}
