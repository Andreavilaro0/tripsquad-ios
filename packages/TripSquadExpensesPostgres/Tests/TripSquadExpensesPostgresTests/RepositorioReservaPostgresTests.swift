// Tests de integración del adaptador Postgres de ReservaRepositorio (wedge
// "quién ya reservó", Task 4). Mismo patrón que
// RepositorioItinerarioPostgresTests.swift: se saltan si PG_TEST != "1"
// (local sin Docker); el CI la levanta como service container, aplica las
// migraciones de db/ (incluida 0008) y corre estos tests con PG_TEST=1.
//
// Cada test siembra su propio viaje + actividad de itinerario (FK de
// itinerary_reservations -> itinerary_items, ON DELETE CASCADE de la 0008),
// trips.id/itinerary_items.id son PK global -> tests en paralelo son seguros.

import Foundation
import Testing
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadExpensesPostgres

@Suite("Adaptador Postgres de reservas (integración)", .enabled(if: pgHabilitado))
struct RepositorioReservaPostgresTests {

    let ana = MiembroId("ana-reserva"), bea = MiembroId("bea-reserva")

    /// Levanta un cliente, siembra un viaje + una actividad de itinerario
    /// (la reserva cuelga de ella por FK), corre el cuerpo con el repo, el
    /// tripId y el activityId ya sembrados.
    func conRepo(_ body: (RepositorioPostgres, String, String) async throws -> Void) async throws {
        let host = ProcessInfo.processInfo.environment["PG_TEST_HOST"] ?? "localhost"
        let config = PostgresClient.Configuration(
            host: host, port: 5432, username: "postgres", password: "postgres",
            database: "tripsquad", tls: .disable)
        let client = PostgresClient(configuration: config)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let repo = RepositorioPostgres(client: client)
            let trip = "trip-r-" + UUID().uuidString.prefix(8)
            let activityId = "item-r-" + UUID().uuidString
            try await client.query("INSERT INTO trips (id, currency_reference) VALUES (\(trip), 'EUR')")
            try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(trip), \(ana.raw))")
            try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(trip), \(bea.raw))")
            try await client.query("""
                INSERT INTO itinerary_items (id, trip_id, title, day, order_index, created_by)
                VALUES (\(activityId), \(trip), 'Vuelo de ida', '2026-08-01'::date, 0, \(ana.raw))
                """)
            try await body(repo, trip, activityId)
            group.cancelAll()
        }
    }

    // MARK: - Round trip cadaUnoElSuyo

    @Test func upsertYLeeCadaUnoElSuyo() async throws {
        try await conRepo { repo, trip, activityId in
            let ahora = Date()
            let r = Reserva(activityId: activityId, tripId: trip, kind: .vuelo,
                            mode: .cadaUnoElSuyo(estados: [ana: .pendiente, bea: .reservado]))
            try await repo.upsert(r, ahora: ahora)

            let leido = try await repo.reserva(activityId: activityId, en: trip)
            #expect(leido == r)
        }
    }

    // MARK: - Round trip unoParaTodos

    @Test func upsertYLeeUnoParaTodos() async throws {
        try await conRepo { repo, trip, activityId in
            let r = Reserva(activityId: activityId, tripId: trip, kind: .hotel,
                            mode: .unoParaTodos(responsable: ana, estado: .pendiente))
            try await repo.upsert(r, ahora: Date())

            let leido = try await repo.reserva(activityId: activityId, en: trip)
            #expect(leido == r)
        }
    }

    @Test func upsertYLeeUnoParaTodosSinResponsable() async throws {
        try await conRepo { repo, trip, activityId in
            let r = Reserva(activityId: activityId, tripId: trip, kind: .coche,
                            mode: .unoParaTodos(responsable: nil, estado: .pendiente))
            try await repo.upsert(r, ahora: Date())

            let leido = try await repo.reserva(activityId: activityId, en: trip)
            #expect(leido == r)
        }
    }

    @Test func reservaInexistenteDevuelveNil() async throws {
        try await conRepo { repo, trip, _ in
            let leido = try await repo.reserva(activityId: "no-existe", en: trip)
            #expect(leido == nil)
        }
    }

    // MARK: - marcarEstado

    @Test func marcarEstadoDeUnMiembroEnCadaUnoElSuyo() async throws {
        try await conRepo { repo, trip, activityId in
            try await repo.upsert(Reserva(activityId: activityId, tripId: trip, kind: .vuelo,
                mode: .cadaUnoElSuyo(estados: [ana: .pendiente, bea: .pendiente])), ahora: Date())

            try await repo.marcarEstado(activityId: activityId, en: trip, miembro: ana, estado: .reservado)

            let leido = try await repo.reserva(activityId: activityId, en: trip)
            #expect(leido?.mode == .cadaUnoElSuyo(estados: [ana: .reservado, bea: .pendiente]))
        }
    }

    @Test func marcarEstadoUnicoEnUnoParaTodos() async throws {
        try await conRepo { repo, trip, activityId in
            try await repo.upsert(Reserva(activityId: activityId, tripId: trip, kind: .hotel,
                mode: .unoParaTodos(responsable: ana, estado: .pendiente)), ahora: Date())

            try await repo.marcarEstado(activityId: activityId, en: trip, miembro: nil, estado: .reservado)

            let leido = try await repo.reserva(activityId: activityId, en: trip)
            #expect(leido?.mode == .unoParaTodos(responsable: ana, estado: .reservado))
        }
    }

    // MARK: - tablero

    @Test func tableroDevuelveTodasOrdenadasPorActivityId() async throws {
        try await conRepo { repo, trip, activityId in
            // Segunda actividad para poder sembrar una segunda reserva del mismo viaje.
            let segundoActivityId = "item-r-" + UUID().uuidString
            try await repo.upsert(Reserva(activityId: activityId, tripId: trip, kind: .vuelo,
                mode: .cadaUnoElSuyo(estados: [ana: .pendiente])), ahora: Date())
            // Sembrar directo en itinerary_items para el segundo activityId (fuera del alcance de ReservaRepositorio).
            try await sembrarActividad(repo, id: segundoActivityId, tripId: trip)
            try await repo.upsert(Reserva(activityId: segundoActivityId, tripId: trip, kind: .hotel,
                mode: .unoParaTodos(responsable: bea, estado: .pendiente)), ahora: Date())

            let tablero = try await repo.tablero(trip)
            #expect(tablero.map(\.activityId) == [activityId, segundoActivityId].sorted())
        }
    }

    /// Helper para sembrar una segunda actividad de itinerario dentro de un test
    /// (la FK de itinerary_reservations exige que exista antes del upsert).
    func sembrarActividad(_ repo: RepositorioPostgres, id: String, tripId: String) async throws {
        try await repo.crear(
            ActividadItinerario(id: id, tripId: tripId, title: "Hotel", day: "2026-08-02",
                                startTime: nil, location: nil, notes: nil, orderIndex: 0, createdBy: ana),
            ahora: Date())
    }

    // MARK: - upsert reemplaza participantes

    @Test func upsertReemplazaParticipantesSinFilasRancias() async throws {
        try await conRepo { repo, trip, activityId in
            try await repo.upsert(Reserva(activityId: activityId, tripId: trip, kind: .vuelo,
                mode: .cadaUnoElSuyo(estados: [ana: .pendiente, bea: .pendiente])), ahora: Date())

            // Reemplaza: bea deja de estar incluida, ana queda reservado.
            try await repo.upsert(Reserva(activityId: activityId, tripId: trip, kind: .vuelo,
                mode: .cadaUnoElSuyo(estados: [ana: .reservado])), ahora: Date())

            let leido = try await repo.reserva(activityId: activityId, en: trip)
            #expect(leido?.mode == .cadaUnoElSuyo(estados: [ana: .reservado]))
        }
    }

    /// Reemplazar de `cadaUnoElSuyo` a `unoParaTodos` no debe dejar filas
    /// huérfanas en itinerary_reservation_members (que romperían la
    /// reconstrucción del modo al leer).
    @Test func upsertReemplazaModoCompletamente() async throws {
        try await conRepo { repo, trip, activityId in
            try await repo.upsert(Reserva(activityId: activityId, tripId: trip, kind: .vuelo,
                mode: .cadaUnoElSuyo(estados: [ana: .pendiente, bea: .reservado])), ahora: Date())

            try await repo.upsert(Reserva(activityId: activityId, tripId: trip, kind: .vuelo,
                mode: .unoParaTodos(responsable: bea, estado: .pendiente)), ahora: Date())

            let leido = try await repo.reserva(activityId: activityId, en: trip)
            #expect(leido?.mode == .unoParaTodos(responsable: bea, estado: .pendiente))
        }
    }

    // MARK: - borrar

    @Test func borrarLimpiaAmbasTablas() async throws {
        try await conRepo { repo, trip, activityId in
            try await repo.upsert(Reserva(activityId: activityId, tripId: trip, kind: .vuelo,
                mode: .cadaUnoElSuyo(estados: [ana: .pendiente, bea: .pendiente])), ahora: Date())
            let antes = try await repo.reserva(activityId: activityId, en: trip)
            #expect(antes != nil)

            try await repo.borrar(activityId: activityId, en: trip)

            let despues = try await repo.reserva(activityId: activityId, en: trip)
            #expect(despues == nil)
            let tablero = try await repo.tablero(trip)
            #expect(!tablero.contains { $0.activityId == activityId })
        }
    }
}
