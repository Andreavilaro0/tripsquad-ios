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
            let r = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "\(id)-k1")
            guard case .creado = r else { Issue.record("esperaba creado, obtuve \(r)"); return }
            let leidos = try await repo.gastos(de: trip)
            #expect(leidos.count == 1)
            #expect(leidos.first?.gasto.importeMinor == 3000)
        }
    }

    @Test func idempotenciaPorClave() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            _ = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "\(id)-k1")
            let previa = try await repo.respuestaPrevia(actor: ana, idempotencyKey: "\(id)-k1")
            guard case .reproducido = previa else { Issue.record("esperaba replay, obtuve \(String(describing: previa))"); return }
            #expect(try await repo.gastos(de: trip).count == 1)
        }
    }

    @Test func dedupeEstructural() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            _ = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "\(id)-k1")
            // Mismo id, otra clave, otro actor -> no duplica.
            let segundo = try await repo.guardar(gasto(id), en: trip, por: ivan, idempotencyKey: "\(id)-k2")
            guard case .reproducido = segundo else { Issue.record("esperaba reproducido, obtuve \(segundo)"); return }
            #expect(try await repo.gastos(de: trip).count == 1)
        }
    }

    /// FUGA ENTRE VIAJES (P1 de la revisión integrada). `expenses.id` es PK GLOBAL y lo
    /// elige el CLIENTE, así que un miembro del viaje B puede mandar el id de un gasto
    /// del viaje A. Antes, la consulta que resuelve ese choque no filtraba por `trip_id`
    /// y devolvía el `etag` y el estado de borrado del gasto AJENO como si fuera propio
    /// (`.reproducido`). Ahora debe ser un rechazo OPACO, sin revelar nada de A.
    @Test func idDeOtroViajeNoFiltraDatosAjenos() async throws {
        let host = ProcessInfo.processInfo.environment["PG_TEST_HOST"] ?? "localhost"
        let config = PostgresClient.Configuration(
            host: host, port: 5432, username: "postgres", password: "postgres",
            database: "tripsquad", tls: .disable)
        let client = PostgresClient(configuration: config)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let repo = RepositorioPostgres(client: client)
            let tripA = "trip-" + UUID().uuidString.prefix(8)
            let tripB = "trip-" + UUID().uuidString.prefix(8)
            for t in [tripA, tripB] {
                try await client.query("INSERT INTO trips (id, currency_reference) VALUES (\(t), 'EUR')")
                try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(t), \(ana.raw))")
                try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(t), \(ivan.raw))")
            }

            let id = nuevoId()
            let enA = try await repo.guardar(gasto(id), en: tripA, por: ana, idempotencyKey: "\(id)-kA")
            guard case .creado = enA else { Issue.record("esperaba creado en A, obtuve \(enA)"); return }

            // El MISMO id desde el viaje B: choca con la PK global del gasto de A.
            let enB = try await repo.guardar(gasto(id), en: tripB, por: ana, idempotencyKey: "\(id)-kB")
            guard case .rechazado(let razon) = enB else {
                Issue.record("un id ocupado en otro viaje debe rechazarse sin filtrar; obtuve \(enB)"); return
            }
            #expect(razon == "id_conflict")
            // Y el viaje B sigue vacío: no se coló ni se "reprodujo" nada de A.
            #expect(try await repo.gastos(de: tripB).isEmpty)
            #expect(try await repo.gastos(de: tripA).count == 1)
            group.cancelAll()
        }
    }

    @Test func conflictoPorEtagRancio() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            _ = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "\(id)-k1")
            let etagViejo = try #require(await repo.gasto(id: id, en: trip)).etag
            _ = try await repo.actualizar(gasto(id, importe: 4000), en: trip, por: ana, ifMatch: etagViejo, idempotencyKey: "\(id)-k2")
            let r = try await repo.actualizar(gasto(id, importe: 9000), en: trip, por: ivan, ifMatch: etagViejo, idempotencyKey: "\(id)-k3")
            guard case .conflicto = r else { Issue.record("esperaba conflicto, obtuve \(r)"); return }
        }
    }

    @Test func tombstoneNoResucita() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            _ = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "\(id)-k1")
            let etag = try #require(await repo.gasto(id: id, en: trip)).etag
            _ = try await repo.eliminar(id: id, en: trip, por: ana, ifMatch: etag, idempotencyKey: "\(id)-k2")
            let recreacion = try await repo.guardar(gasto(id), en: trip, por: ivan, idempotencyKey: "\(id)-k3")
            #expect(recreacion == .rechazado(razon: "deleted"))
            #expect(try await repo.gastos(de: trip).isEmpty)
        }
    }

    @Test func repartoExactoVaATablaTipada() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            let exacto = Gasto(id: id, pagadoPor: ana, importeMinor: 1000,
                               reparto: .exacto([ana: 600, ivan: 400]))
            _ = try await repo.guardar(exacto, en: trip, por: ana, idempotencyKey: "\(id)-k1")
            let leido = try #require(await repo.gasto(id: id, en: trip))
            guard case .exacto(let cuotas) = leido.gasto.reparto else {
                Issue.record("esperaba reparto exacto"); return
            }
            #expect(cuotas[ana] == 600)
            #expect(cuotas[ivan] == 400)
        }
    }

    /// (bead zkm) Al editar el importe, `amount_original` debe seguir a
    /// `amount_reference`. El dominio hoy es mono-moneda (currency_original fijo en
    /// 'EUR'), así que ambas columnas representan el mismo importe; el UPDATE se había
    /// quedado corto y solo tocaba `amount_reference`, dejando `amount_original`
    /// congelado con el valor de creación tras editar.
    @Test func editarActualizaAmountOriginal() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            _ = try await repo.guardar(gasto(id, importe: 3000), en: trip, por: ana, idempotencyKey: "\(id)-k1")
            let etag = try #require(await repo.gasto(id: id, en: trip)).etag
            _ = try await repo.actualizar(gasto(id, importe: 7500), en: trip, por: ana, ifMatch: etag, idempotencyKey: "\(id)-k2")

            let host = ProcessInfo.processInfo.environment["PG_TEST_HOST"] ?? "localhost"
            let config = PostgresClient.Configuration(
                host: host, port: 5432, username: "postgres", password: "postgres",
                database: "tripsquad", tls: .disable)
            let client = PostgresClient(configuration: config)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await client.run() }
                let rows = try await client.query(
                    "SELECT amount_reference, amount_original FROM expenses WHERE id = \(id)")
                for try await (reference, original) in rows.decode((Int64, Int64).self) {
                    #expect(reference == 7500)
                    #expect(original == 7500, "amount_original debe seguir al importe editado")
                }
                group.cancelAll()
            }
        }
    }

    /// (Codex P2) Al editar de reparto EXACTO a igual, las shares tipadas se limpian.
    @Test func editarDeExactoAIgualLimpiaShares() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            let exacto = Gasto(id: id, pagadoPor: ana, importeMinor: 1000, reparto: .exacto([ana: 600, ivan: 400]))
            _ = try await repo.guardar(exacto, en: trip, por: ana, idempotencyKey: "\(id)-k1")
            let etag = try #require(await repo.gasto(id: id, en: trip)).etag
            // Editar a reparto igual.
            _ = try await repo.actualizar(gasto(id, importe: 1000), en: trip, por: ana, ifMatch: etag, idempotencyKey: "\(id)-k2")
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
