// Tests de integración del adaptador Postgres de ChatRepositorio (M6,
// ADR-0021 borrador). Mismo patrón que RepositorioItinerarioPostgresTests.swift:
// se saltan si PG_TEST != "1" (local sin Docker); el CI la levanta como service
// container, aplica las migraciones de db/ (incluida 0006) y corre estos tests
// con PG_TEST=1.
//
// Cada test siembra su propio viaje (trips.id es PK global, tests en paralelo).

import Foundation
import Testing
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadExpensesPostgres

@Suite("Adaptador Postgres de chat (integración)", .enabled(if: pgHabilitado))
struct RepositorioChatPostgresTests {

    let ana = MiembroId("ana-chat")
    let bea = MiembroId("bea-chat")

    /// Levanta un cliente, siembra un viaje con Ana y Bea como miembros, corre
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
            let trip = "trip-c-" + UUID().uuidString.prefix(8)
            try await client.query("INSERT INTO trips (id, currency_reference) VALUES (\(trip), 'EUR')")
            try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(trip), \(ana.raw))")
            try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(trip), \(bea.raw))")
            try await body(repo, trip)
            group.cancelAll()
        }
    }

    @Test func enviarYListarOrdenaPorIdYSinceFunciona() async throws {
        try await conRepo { repo, trip in
            let m1 = try await repo.enviar(tripId: trip, autor: ana, body: "hola", ahora: Date())
            let m2 = try await repo.enviar(tripId: trip, autor: bea, body: "qué tal", ahora: Date())
            let m3 = try await repo.enviar(tripId: trip, autor: ana, body: "todo bien", ahora: Date())

            // Cursor monotónico creciente.
            #expect(m1.id < m2.id)
            #expect(m2.id < m3.id)
            #expect(m1.deletedAt == nil)
            #expect(m1.body == "hola")
            #expect(m1.autor == ana)
            #expect(m1.tripId == trip)

            let todos = try await repo.mensajes(tripId: trip, since: nil, limit: 50)
            #expect(todos.map(\.body) == ["hola", "qué tal", "todo bien"])
            #expect(todos.map(\.id) == [m1.id, m2.id, m3.id])

            // since = m1.id -> solo lo que viene después de m1 (id > since).
            let desdeM1 = try await repo.mensajes(tripId: trip, since: m1.id, limit: 50)
            #expect(desdeM1.map(\.id) == [m2.id, m3.id])

            // since = m3.id -> nada más.
            let desdeM3 = try await repo.mensajes(tripId: trip, since: m3.id, limit: 50)
            #expect(desdeM3.isEmpty)
        }
    }

    @Test func limitRecortaYRespetaOrdenCronologico() async throws {
        try await conRepo { repo, trip in
            var enviados: [Mensaje] = []
            for i in 0..<5 {
                enviados.append(try await repo.enviar(tripId: trip, autor: ana, body: "msg \(i)", ahora: Date()))
            }

            let primerosDos = try await repo.mensajes(tripId: trip, since: nil, limit: 2)
            #expect(primerosDos.map(\.id) == [enviados[0].id, enviados[1].id])
        }
    }

    @Test func mensaje() async throws {
        try await conRepo { repo, trip in
            let enviado = try await repo.enviar(tripId: trip, autor: ana, body: "hola", ahora: Date())

            let leido = try await repo.mensaje(id: enviado.id, en: trip)
            #expect(leido?.id == enviado.id)
            #expect(leido?.body == "hola")
            #expect(leido?.autor == ana)
            #expect(leido?.deletedAt == nil)

            // Otro tripId no ve el mensaje (scope por trip, sin fuga).
            #expect(try await repo.mensaje(id: enviado.id, en: "otro-trip") == nil)
            #expect(try await repo.mensaje(id: 9_999_999, en: trip) == nil)
        }
    }

    @Test func borrarEsSoftDeleteYSustituyeElBodyPorElMarcador() async throws {
        try await conRepo { repo, trip in
            let enviado = try await repo.enviar(tripId: trip, autor: ana, body: "hola", ahora: Date())
            let ahoraBorrado = Date()
            try await repo.borrar(id: enviado.id, en: trip, ahora: ahoraBorrado)

            // El mensaje NO desaparece del hilo: sigue estando en `mensaje` y en
            // `mensajes`, pero con el body sustituido por el marcador.
            let leido = try await repo.mensaje(id: enviado.id, en: trip)
            #expect(leido?.body == Mensaje.marcadorBorrado)
            #expect(leido?.deletedAt != nil)

            let lista = try await repo.mensajes(tripId: trip, since: nil, limit: 50)
            #expect(lista.first?.body == Mensaje.marcadorBorrado)
            #expect(lista.count == 1)
        }
    }

    @Test func borrarEsIdempotenteYConservaLaFechaDelPrimerBorrado() async throws {
        try await conRepo { repo, trip in
            let enviado = try await repo.enviar(tripId: trip, autor: ana, body: "hola", ahora: Date())
            let primerBorrado = Date()
            try await repo.borrar(id: enviado.id, en: trip, ahora: primerBorrado)
            let leidoTrasPrimero = try await repo.mensaje(id: enviado.id, en: trip)

            // Segundo borrado, con otra fecha: no debe pisar `deleted_at`.
            let segundoBorrado = primerBorrado.addingTimeInterval(3600)
            try await repo.borrar(id: enviado.id, en: trip, ahora: segundoBorrado)
            let leidoTrasSegundo = try await repo.mensaje(id: enviado.id, en: trip)

            #expect(leidoTrasSegundo?.body == Mensaje.marcadorBorrado)
            #expect(leidoTrasPrimero?.deletedAt == leidoTrasSegundo?.deletedAt)
        }
    }
}
