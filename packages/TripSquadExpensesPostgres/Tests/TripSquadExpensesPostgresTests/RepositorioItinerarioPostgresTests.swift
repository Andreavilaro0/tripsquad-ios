// Tests de integración del adaptador Postgres de ItinerarioRepositorio (M5,
// ADR-0020 borrador). Mismo patrón que RepositorioVotacionPostgresTests.swift:
// se saltan si PG_TEST != "1" (local sin Docker); el CI la levanta como service
// container, aplica las migraciones de db/ (incluida 0005) y corre estos tests
// con PG_TEST=1.
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

            let lista = try await repo.listar(trip)
            #expect(lista.map(\.title) == ["Coliseo", "Foro Romano", "Vaticano"])
            #expect(lista.map(\.day) == ["2026-08-01", "2026-08-01", "2026-08-02"])
            #expect(lista.first?.startTime == "10:00")
            #expect(lista.first?.location == "Roma")
            #expect(lista.first?.notes == "llevar cámara")
            #expect(lista.first?.createdBy == ana)
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

    @Test func actualizar() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            try await repo.crear(actividad(id, tripId: trip), ahora: Date())

            let editada = ActividadItinerario(
                id: id, tripId: trip, title: "Coliseo (editado)", day: "2026-08-03",
                startTime: "11:30", location: "Roma centro", notes: nil, orderIndex: 5, createdBy: ana)
            try await repo.actualizar(editada, ahora: Date())

            let leida = try await repo.item(id: id, en: trip)
            #expect(leida?.title == "Coliseo (editado)")
            #expect(leida?.day == "2026-08-03")
            #expect(leida?.startTime == "11:30")
            #expect(leida?.location == "Roma centro")
            #expect(leida?.notes == nil)
            #expect(leida?.orderIndex == 5)
        }
    }

    @Test func borrar() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            try await repo.crear(actividad(id, tripId: trip), ahora: Date())
            #expect(try await repo.item(id: id, en: trip) != nil)

            try await repo.borrar(id: id, en: trip)
            #expect(try await repo.item(id: id, en: trip) == nil)

            let lista = try await repo.listar(trip)
            #expect(!lista.contains { $0.id == id })
        }
    }
}
