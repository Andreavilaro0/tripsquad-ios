// Tests de integración del adaptador Postgres de ItinerarioRepositorio (M5,
// ADR-0020 borrador; ETag/If-Match bead 201, migración 0010). Mismo patrón que
// RepositorioVotacionPostgresTests.swift: se saltan si PG_TEST != "1" (local
// sin Docker); el CI la levanta como service container, aplica las
// migraciones de db/ (incluida 0010) y corre estos tests con PG_TEST=1.
//
// Cada test siembra su propio viaje (trips.id es PK global, tests en paralelo).

import Foundation
import Testing
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadExpensesPostgres

@Suite("Adaptador Postgres de itinerario (integración)", .enabled(if: pgHabilitado))
struct RepositorioItinerarioPostgresTests {

    let ana = MiembroId("ana-itin")

    /// Levanta un cliente, siembra un viaje con Ana como miembro, corre el
    /// cuerpo con el repo y el tripId.
    func conRepo(_ body: (RepositorioPostgres, String) async throws -> Void) async throws {
        let host = ProcessInfo.processInfo.environment["PG_TEST_HOST"] ?? "localhost"
        let config = PostgresClient.Configuration(
            host: host, port: 5432, username: "postgres", password: "postgres",
            database: "tripsquad", tls: .disable)
        let client = PostgresClient(configuration: config)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let repo = RepositorioPostgres(client: client)
            let trip = "trip-i-" + UUID().uuidString.prefix(8)
            try await client.query("INSERT INTO trips (id, currency_reference) VALUES (\(trip), 'EUR')")
            try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(trip), \(ana.raw))")
            try await body(repo, trip)
            group.cancelAll()
        }
    }

    func nuevoId() -> String { "item-" + UUID().uuidString }

    func actividad(_ id: String, tripId: String, day: String = "2026-08-01", orderIndex: Int = 0, title: String = "Coliseo") -> ActividadItinerario {
        ActividadItinerario(
            id: id, tripId: tripId, title: title, day: day, startTime: "10:00",
            location: "Roma", notes: "llevar cámara", orderIndex: orderIndex, createdBy: ana)
    }

    @Test func crearYListarOrdenaPorDayYOrderIndex() async throws {
        try await conRepo { repo, trip in
            let ahora = Date()
            // Se insertan desordenados a propósito: el repo debe devolverlos en
            // orden (day, orderIndex), no en orden de inserción.
            let c = actividad(nuevoId(), tripId: trip, day: "2026-08-02", orderIndex: 0, title: "Vaticano")
            let a = actividad(nuevoId(), tripId: trip, day: "2026-08-01", orderIndex: 1, title: "Foro Romano")
            let b = actividad(nuevoId(), tripId: trip, day: "2026-08-01", orderIndex: 0, title: "Coliseo")
            try await repo.crear(c, ahora: ahora)
            try await repo.crear(a, ahora: ahora)
            try await repo.crear(b, ahora: ahora)

            let lista = try await repo.listar(trip, limit: 200)
            #expect(lista.map { $0.actividad.title } == ["Coliseo", "Foro Romano", "Vaticano"])
            #expect(lista.map { $0.actividad.day } == ["2026-08-01", "2026-08-01", "2026-08-02"])
            #expect(lista.first?.actividad.startTime == "10:00")
            #expect(lista.first?.actividad.location == "Roma")
            #expect(lista.first?.actividad.notes == "llevar cámara")
            #expect(lista.first?.actividad.createdBy == ana)
            // Cada item lleva un etag no vacío (bead 201).
            #expect(lista.allSatisfy { !$0.etag.isEmpty })
        }
    }

    @Test func crearDevuelveElEtagInicial() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            let conEtag = try await repo.crear(actividad(id, tripId: trip), ahora: Date())
            #expect(!conEtag.etag.isEmpty)
            #expect(conEtag.actividad.id == id)

            // El etag devuelto en la creación coincide con el que aparece al listar.
            let lista = try await repo.listar(trip, limit: 200)
            #expect(lista.first { $0.actividad.id == id }?.etag == conEtag.etag)
        }
    }

    @Test func item() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            try await repo.crear(actividad(id, tripId: trip), ahora: Date())

            let leido = try await repo.item(id: id, en: trip)
            #expect(leido?.id == id)
            #expect(leido?.day == "2026-08-01")
            #expect(leido?.title == "Coliseo")

            // Otro tripId no ve el item (scope por trip, sin fuga).
            #expect(try await repo.item(id: id, en: "otro-trip") == nil)
            #expect(try await repo.item(id: "no-existe", en: trip) == nil)
        }
    }

    @Test func actualizarConIfMatchCorrectoAplicaYRenuevaElEtag() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            let creada = try await repo.crear(actividad(id, tripId: trip), ahora: Date())

            let editada = ActividadItinerario(
                id: id, tripId: trip, title: "Coliseo (editado)", day: "2026-08-03",
                startTime: "11:30", location: "Roma centro", notes: nil, orderIndex: 5, createdBy: ana)
            guard case .ok(let resultado) = try await repo.actualizar(editada, ifMatch: creada.etag, ahora: Date()) else {
                Issue.record("esperaba .ok"); return
            }
            #expect(resultado.etag != creada.etag)
            #expect(resultado.actividad.title == "Coliseo (editado)")

            let leida = try await repo.item(id: id, en: trip)
            #expect(leida?.title == "Coliseo (editado)")
            #expect(leida?.day == "2026-08-03")
            #expect(leida?.startTime == "11:30")
            #expect(leida?.location == "Roma centro")
            #expect(leida?.notes == nil)
            #expect(leida?.orderIndex == 5)
        }
    }

    /// Corazón del bead 201: el UPDATE es condicional por etag. Un `If-Match` que ya
    /// no coincide (otra edición ya pasó) NO aplica el cambio y devuelve el etag
    /// SERVIDOR actual — mismo patrón atómico que `RepositorioPostgres.actualizar` de
    /// gastos (WHERE con el etag, no lectura-antes-de-escritura).
    @Test func actualizarConEtagViejoEsConflictoYNoAplicaElCambio() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            let creada = try await repo.crear(actividad(id, tripId: trip), ahora: Date())

            let primeraEdicion = ActividadItinerario(
                id: id, tripId: trip, title: "v2", day: "2026-08-01", startTime: "10:00",
                location: "Roma", notes: nil, orderIndex: 0, createdBy: ana)
            guard case .ok(let resultado1) = try await repo.actualizar(primeraEdicion, ifMatch: creada.etag, ahora: Date()) else {
                Issue.record("esperaba .ok en la 1ª edición"); return
            }

            // 2ª edición con el etag VIEJO (el de la creación) → conflicto, no aplica.
            let segundaEdicion = ActividadItinerario(
                id: id, tripId: trip, title: "v3 (perdedor)", day: "2026-08-01", startTime: "10:00",
                location: "Roma", notes: nil, orderIndex: 0, createdBy: ana)
            let resultado2 = try await repo.actualizar(segundaEdicion, ifMatch: creada.etag, ahora: Date())
            guard case .conflicto(let serverEtag) = resultado2 else {
                Issue.record("esperaba .conflicto"); return
            }
            #expect(serverEtag == resultado1.etag)

            // El conflicto NO tocó la fila: sigue con el título de la 1ª edición.
            let leida = try await repo.item(id: id, en: trip)
            #expect(leida?.title == "v2")
        }
    }

    /// Actualizar una actividad borrada/inexistente (o de otro trip) → `.noEncontrado`,
    /// distinto de `.conflicto` (no hay etag servidor que ofrecer).
    @Test func actualizarSobreInexistenteEsNoEncontrado() async throws {
        try await conRepo { repo, trip in
            let fantasma = ActividadItinerario(
                id: "no-existe", tripId: trip, title: "x", day: "2026-08-01", createdBy: ana)
            let resultado = try await repo.actualizar(fantasma, ifMatch: "cualquier-etag", ahora: Date())
            #expect(resultado == .noEncontrado)
        }
    }

    @Test func borrar() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            try await repo.crear(actividad(id, tripId: trip), ahora: Date())
            #expect(try await repo.item(id: id, en: trip) != nil)

            _ = try await repo.borrar(id: id, en: trip, por: ana)
            #expect(try await repo.item(id: id, en: trip) == nil)

            let lista = try await repo.listar(trip, limit: 200)
            #expect(!lista.contains { $0.actividad.id == id })
        }
    }

    // Bead 48g: el borrado es ATÓMICO por membresía en el MISMO statement (CTE). Si la
    // membresía del actor fue revocada (expulsión intra-request), `borrar` devuelve `false`
    // y la actividad NO se borra — cierra del todo la ventana TOCTOU a nivel de BD.
    @Test func borrarConMembresiaRevocadaDevuelveFalseYNoBorra() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            try await repo.crear(actividad(id, tripId: trip), ahora: Date())
            // Revocar la membresía de ana (simula la expulsión que ocurre durante la request).
            try await repo.client.query(
                "UPDATE trip_members SET left_at = now() WHERE trip_id = \(trip) AND member_id = \(ana.raw)")

            let borrado = try await repo.borrar(id: id, en: trip, por: ana)
            #expect(borrado == false)                                  // membresía revocada -> no autoriza
            #expect(try await repo.item(id: id, en: trip) != nil)      // la actividad SIGUE (atómico)
        }
    }

    // MARK: - Tope + desempate por id

    /// `limit` recorta y el orden es TOTAL: tres actividades del MISMO día con el MISMO
    /// `order_index` sólo se pueden ordenar por `id`. Sin ese desempate (que es lo que
    /// había antes), Postgres podía devolver cualquiera de las tres como "primera" y la
    /// página nº2 repetía u omitía ítems.
    @Test func listarRespetaElLimitYDesempataPorId() async throws {
        try await conRepo { repo, trip in
            let ahora = Date()
            var ids: [String] = []
            for i in 0..<3 {
                let id = nuevoId()
                ids.append(id)
                try await repo.crear(actividad(id, tripId: trip, day: "2026-09-01", orderIndex: 0, title: "act-\(i)"),
                                     ahora: ahora)
            }

            let completa = try await repo.listar(trip, limit: 200).map { $0.actividad.id }
            #expect(completa == ids.sorted(), "mismo day y order_index -> el orden lo fija el id")
            #expect(try await repo.listar(trip, limit: 200).map { $0.actividad.id } == completa)   // repetible
            #expect(try await repo.listar(trip, limit: 2).map { $0.actividad.id } == Array(completa.prefix(2)))
            #expect(try await repo.listar(trip, limit: 1).count == 1)
        }
    }
}
