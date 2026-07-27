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

    /// Clave única por test: `idempotency_keys` es (user_id, key) global y el contenedor de
    /// CI persiste entre tests, así que no se pueden reusar cadenas de clave.
    func nuevaKey() -> String { "idem-" + UUID().uuidString }

    // Idempotencia genérica de respuesta (bead 379) contra Postgres real: claim-first,
    // replay con headers+body byte-exacto, en-vuelo, liberar y scope por actor.
    @Test func idempotenciaGenericaPostgres() async throws {
        try await conRepo { repo, _ in
            // 1. reclamar -> reclamado; congelar; reclamar -> replay idéntico (code+headers+body).
            let k1 = nuevaKey()
            guard case .reclamado = try await repo.reclamar(actor: ana, key: k1) else {
                Issue.record("primer reclamo debe ser reclamado"); return
            }
            let resp = RespuestaCongelada(code: 201, headers: ["etag": "abc-123"], body: Array(#"{"id":"x"}"#.utf8))
            try await repo.congelar(actor: ana, key: k1, respuesta: resp)
            guard case .replay(let reproducida) = try await repo.reclamar(actor: ana, key: k1) else {
                Issue.record("tras congelar debe reproducir"); return
            }
            #expect(reproducida == resp)   // code, headers y body byte-exacto

            // 2. reclamar dos veces sin congelar -> el segundo es enVuelo.
            let k2 = nuevaKey()
            guard case .reclamado = try await repo.reclamar(actor: ana, key: k2) else {
                Issue.record("k2 primer reclamo"); return
            }
            guard case .enVuelo = try await repo.reclamar(actor: ana, key: k2) else {
                Issue.record("k2 segundo reclamo sin congelar debe ser enVuelo"); return
            }

            // 3. liberar un reclamo no congelado permite volver a reclamarlo.
            try await repo.liberar(actor: ana, key: k2)
            guard case .reclamado = try await repo.reclamar(actor: ana, key: k2) else {
                Issue.record("tras liberar, debe poder reclamarse de nuevo"); return
            }

            // 4. scope por actor: la misma clave de ivan es independiente de la de ana.
            let k3 = nuevaKey()
            _ = try await repo.reclamar(actor: ana, key: k3)
            try await repo.congelar(actor: ana, key: k3, respuesta: resp)
            guard case .reclamado = try await repo.reclamar(actor: ivan, key: k3) else {
                Issue.record("la clave de ivan es independiente de la de ana"); return
            }
        }
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

    // MARK: - Historial de ediciones (p4b) + RGPD (o1v, ADR-0027)

    /// Editar deja una revisión (ADR-0015 §15) con `editedBy` = quien EDITÓ, no
    /// quien pagó — mismo escenario que `CasosDeUsoTests.editarRegistraRevision`,
    /// ahora contra Postgres real.
    @Test func editarDejaRevisionConEditedByCorrecto() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            _ = try await repo.guardar(gasto(id), en: trip, por: ana, idempotencyKey: "\(id)-k1")
            let etag = try #require(await repo.gasto(id: id, en: trip)).etag
            _ = try await repo.actualizar(gasto(id, importe: 5000), en: trip, por: ivan, ifMatch: etag, idempotencyKey: "\(id)-k2")

            let revisiones = try await repo.revisiones(deGasto: id, en: trip, limit: 50)
            #expect(revisiones.count == 1)
            #expect(revisiones.first?.editedBy == ivan)
        }
    }

    /// FUGA ENTRE VIAJES: un `expenseId` de OTRO viaje no debe filtrar su
    /// historial — el JOIN con `expenses` filtra por `trip_id` (mismo criterio
    /// que `idDeOtroViajeNoFiltraDatosAjenos`).
    @Test func revisionesNoFiltranEntreViajes() async throws {
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
            _ = try await repo.guardar(gasto(id), en: tripA, por: ana, idempotencyKey: "\(id)-k1")
            let etag = try #require(await repo.gasto(id: id, en: tripA)).etag
            _ = try await repo.actualizar(gasto(id, importe: 5000), en: tripA, por: ana, ifMatch: etag, idempotencyKey: "\(id)-k2")

            // Mismo expenseId, pero consultado desde tripB: NO debe ver el historial de A.
            let revisionesDesdeB = try await repo.revisiones(deGasto: id, en: tripB, limit: 50)
            #expect(revisionesDesdeB.isEmpty, "el historial de un gasto de OTRO viaje no debe filtrarse")
            let revisionesDesdeA = try await repo.revisiones(deGasto: id, en: tripA, limit: 50)
            #expect(revisionesDesdeA.count == 1)
            group.cancelAll()
        }
    }

    /// RGPD (bead o1v, ADR-0027, DECISIÓN de Andrea 2026-07-27): hard-delete
    /// GLOBAL por `edited_by`. Borra SOLO las revisiones del autor que ejerce el
    /// derecho al olvido; el gasto (de OTRO dueño) y las revisiones de otros
    /// autores sobreviven — el hallazgo de Gemini que motivó este ADR.
    ///
    /// El "autor que olvida" usa un `MiembroId` ÚNICO por ejecución (no `ivan`,
    /// compartido por toda la suite): `olvidarRevisionesDe` es GLOBAL a
    /// propósito (borra en TODOS los viajes), así que reusar un actor común
    /// recogería revisiones de OTROS tests de esta misma suite — falso
    /// positivo/negativo por contaminación cruzada entre tests, no un bug del
    /// repo. `edited_by` no tiene FK a `trip_members`: el repo no valida
    /// membresía (eso es del caso de uso), así que un id "no-miembro" es válido
    /// aquí.
    @Test func olvidarRevisionesDeBorraSoloLasDelAutorGlobalmente() async throws {
        try await conRepo { repo, trip in
            let autorQueOlvida = MiembroId("olvido-" + UUID().uuidString)
            let id1 = nuevoId()
            let id2 = nuevoId()
            _ = try await repo.guardar(gasto(id1), en: trip, por: ana, idempotencyKey: "\(id1)-k1")
            _ = try await repo.guardar(gasto(id2), en: trip, por: ana, idempotencyKey: "\(id2)-k1")
            let etag1 = try #require(await repo.gasto(id: id1, en: trip)).etag
            let etag2 = try #require(await repo.gasto(id: id2, en: trip)).etag
            // `autorQueOlvida` edita AMBOS gastos de Ana (dos revisiones suyas, en dos gastos).
            _ = try await repo.actualizar(gasto(id1, importe: 4000), en: trip, por: autorQueOlvida, ifMatch: etag1, idempotencyKey: "\(id1)-k2")
            _ = try await repo.actualizar(gasto(id2, importe: 4000), en: trip, por: autorQueOlvida, ifMatch: etag2, idempotencyKey: "\(id2)-k2")
            // Ana también edita el primero (revisión suya propia).
            let etag1b = try #require(await repo.gasto(id: id1, en: trip)).etag
            _ = try await repo.actualizar(gasto(id1, importe: 4500), en: trip, por: ana, ifMatch: etag1b, idempotencyKey: "\(id1)-k3")

            let borradas = try await repo.olvidarRevisionesDe(autorQueOlvida)
            #expect(borradas == 2)

            let revisionesId1 = try await repo.revisiones(deGasto: id1, en: trip, limit: 50)
            #expect(revisionesId1.count == 1)
            #expect(revisionesId1.allSatisfy { $0.editedBy == ana })
            let revisionesId2 = try await repo.revisiones(deGasto: id2, en: trip, limit: 50)
            #expect(revisionesId2.isEmpty)

            // Los gastos de Ana (el dueño) siguen intactos: el olvido de `autorQueOlvida` no los tocó.
            #expect(try await repo.gasto(id: id1, en: trip) != nil)
            #expect(try await repo.gasto(id: id2, en: trip) != nil)
        }
    }
}
