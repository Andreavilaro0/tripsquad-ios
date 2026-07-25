// Tests de integración del adaptador Postgres de VotacionRepositorio (M4,
// ADR-0019 borrador). Mismo patrón que RepositorioViajePostgresTests.swift: se
// saltan si PG_TEST != "1" (local sin Docker); el CI la levanta como service
// container, aplica las migraciones de db/ (incluida 0004) y corre estos tests
// con PG_TEST=1.
//
// Cada test siembra su propio viaje (trips.id es PK global, tests en paralelo).

import Foundation
import Testing
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadExpensesPostgres

@Suite("Adaptador Postgres de votaciones (integración)", .enabled(if: pgHabilitado))
struct RepositorioVotacionPostgresTests {

    let ana = MiembroId("ana-poll"), ivan = MiembroId("ivan-poll")

    /// Levanta un cliente, siembra un viaje con Ana e Iván como miembros, corre
    /// el cuerpo con el repo y el tripId.
    func conRepo(_ body: (RepositorioPostgres, String) async throws -> Void) async throws {
        let host = ProcessInfo.processInfo.environment["PG_TEST_HOST"] ?? "localhost"
        let config = PostgresClient.Configuration(
            host: host, port: 5432, username: "postgres", password: "postgres",
            database: "tripsquad", tls: .disable)
        let client = PostgresClient(configuration: config)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let repo = RepositorioPostgres(client: client)
            let trip = "trip-p-" + UUID().uuidString.prefix(8)
            try await client.query("INSERT INTO trips (id, currency_reference) VALUES (\(trip), 'EUR')")
            try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(trip), \(ana.raw))")
            try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(trip), \(ivan.raw))")
            try await body(repo, trip)
            group.cancelAll()
        }
    }

    func nuevoId() -> String { "poll-" + UUID().uuidString }

    func votacion(_ id: String, tripId: String, options: [String] = ["playa", "montaña"]) -> Votacion {
        Votacion(id: id, tripId: tripId, question: "¿Playa o montaña?", options: options, createdBy: ana, closedAt: nil)
    }

    @Test func crearYLeer() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            try await repo.crear(votacion(id, tripId: trip))

            let leida = try await repo.votacion(id: id, en: trip)
            #expect(leida?.question == "¿Playa o montaña?")
            #expect(leida?.options == ["playa", "montaña"])
            #expect(leida?.createdBy == ana)
            #expect(leida?.closedAt == nil)

            let lista = try await repo.votacionesDe(trip, limit: 200)
            #expect(lista.contains { $0.id == id })
        }
    }

    @Test func votarYCambiarVotoEsUpsert() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            try await repo.crear(votacion(id, tripId: trip))
            let ahora = Date()

            let r1 = try await repo.votar(pollId: id, tripId: trip, member: ivan, choice: "playa", ahora: ahora)
            #expect(r1 == .registrado)

            // Cambia de opción: mismo (pollId, member) -> upsert, no duplica.
            let r2 = try await repo.votar(pollId: id, tripId: trip, member: ivan, choice: "montaña", ahora: ahora.addingTimeInterval(60))
            #expect(r2 == .registrado)

            let resultado = try await repo.resultado(pollId: id, en: trip)
            #expect(resultado?.conteo["playa"] == 0)
            #expect(resultado?.conteo["montaña"] == 1)
            #expect(resultado?.votos.count == 1)
            #expect(resultado?.votos.first?.0 == ivan)
            #expect(resultado?.votos.first?.1 == "montaña")
        }
    }

    @Test func votarOptionInvalida() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            try await repo.crear(votacion(id, tripId: trip))
            let r = try await repo.votar(pollId: id, tripId: trip, member: ivan, choice: "luna", ahora: Date())
            #expect(r == .rechazado(razon: "invalid_option"))
        }
    }

    @Test func votarEnPollInexistente() async throws {
        try await conRepo { repo, trip in
            let r = try await repo.votar(pollId: "no-existe", tripId: trip, member: ivan, choice: "playa", ahora: Date())
            #expect(r == .rechazado(razon: "poll_not_found"))
        }
    }

    @Test func votarEnCerradaSeRechaza() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            let ahora = Date()
            try await repo.crear(votacion(id, tripId: trip))
            try await repo.cerrar(pollId: id, en: trip, ahora: ahora)

            let r = try await repo.votar(pollId: id, tripId: trip, member: ivan, choice: "playa", ahora: ahora)
            #expect(r == .rechazado(razon: "poll_closed"))
        }
    }

    @Test func resultadoConConteosIncluyeOpcionesEn0Votos() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            try await repo.crear(votacion(id, tripId: trip, options: ["playa", "montaña", "ciudad"]))
            let ahora = Date()
            _ = try await repo.votar(pollId: id, tripId: trip, member: ana, choice: "playa", ahora: ahora)
            _ = try await repo.votar(pollId: id, tripId: trip, member: ivan, choice: "playa", ahora: ahora)

            let resultado = try await repo.resultado(pollId: id, en: trip)
            #expect(resultado?.conteo["playa"] == 2)
            #expect(resultado?.conteo["montaña"] == 0)
            #expect(resultado?.conteo["ciudad"] == 0)
            #expect(resultado?.votos.count == 2)
            // Orden estable por MiembroId.
            #expect(resultado?.votos.map(\.0) == [ana, ivan].sorted())
        }
    }

    @Test func cerrarPersisteClosedAt() async throws {
        try await conRepo { repo, trip in
            let id = nuevoId()
            let ahora = Date()
            try await repo.crear(votacion(id, tripId: trip))
            #expect(try await repo.votacion(id: id, en: trip)?.closedAt == nil)

            try await repo.cerrar(pollId: id, en: trip, ahora: ahora)
            let cerrada = try await repo.votacion(id: id, en: trip)
            #expect(cerrada?.closedAt != nil)
        }
    }

    @Test func resultadoDePollInexistenteEsNil() async throws {
        try await conRepo { repo, trip in
            let resultado = try await repo.resultado(pollId: "no-existe", en: trip)
            #expect(resultado == nil)
        }
    }

    // MARK: - Tope + orden estable

    /// `votacionesDe` respeta el `LIMIT` y el `ORDER BY id` (total, `id` es PK):
    /// la página corta es el PREFIJO de la completa, nunca un subconjunto al azar.
    @Test func votacionesDeRespetaElLimitYTieneOrdenEstable() async throws {
        try await conRepo { repo, trip in
            var ids: [String] = []
            for _ in 0..<3 {
                let id = nuevoId()
                ids.append(id)
                try await repo.crear(votacion(id, tripId: trip))
            }

            let completa = try await repo.votacionesDe(trip, limit: 200).map(\.id)
            #expect(completa == ids.sorted())
            #expect(try await repo.votacionesDe(trip, limit: 200).map(\.id) == completa)   // repetible
            #expect(try await repo.votacionesDe(trip, limit: 2).map(\.id) == Array(completa.prefix(2)))
            #expect(try await repo.votacionesDe(trip, limit: 1).count == 1)
        }
    }
}
