// Tests de integración del adaptador Postgres de FotoRepositorio (M7 Task 2,
// ADR-0022 borrador). Mismo patrón que RepositorioItinerarioPostgresTests.swift:
// se saltan si PG_TEST != "1" (local sin Docker); el CI la levanta como service
// container, aplica las migraciones de db/ (incluida 0007) y corre estos tests
// con PG_TEST=1.
//
// Cada test siembra su propio viaje (trips.id es PK global, tests en paralelo).

import Foundation
import Testing
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadExpensesPostgres

@Suite("Adaptador Postgres de fotos (integración)", .enabled(if: pgHabilitado))
struct RepositorioFotoPostgresTests {

    let ana = MiembroId("ana-foto")

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
            let trip = "trip-f-" + UUID().uuidString.prefix(8)
            try await client.query("INSERT INTO trips (id, currency_reference) VALUES (\(trip), 'EUR')")
            try await client.query("INSERT INTO trip_members (trip_id, member_id) VALUES (\(trip), \(ana.raw))")
            try await body(repo, trip)
            group.cancelAll()
        }
    }

    func nuevaFoto(_ id: String, tripId: String, caption: String? = nil, createdAt: Date = Date()) -> Foto {
        Foto(
            id: id, tripId: tripId, uploadedBy: ana, storageKey: "\(tripId)/\(id)",
            contentType: "image/jpeg", sizeBytes: 12345, caption: caption, status: .pending,
            createdAt: createdAt)
    }

    @Test func crearPendienteYListarSoloListasTrasMarcar() async throws {
        try await conRepo { repo, trip in
            let a = nuevaFoto("foto-a", tripId: trip, createdAt: Date())
            let b = nuevaFoto("foto-b", tripId: trip, createdAt: Date().addingTimeInterval(1))
            try await repo.crearPendiente(a)
            try await repo.crearPendiente(b)

            // Ambas pending: listar(soloListas: false) las ve, soloListas: true no ve ninguna.
            #expect(try await repo.listar(trip, soloListas: false, limit: 200).map(\.id) == ["foto-a", "foto-b"])
            #expect(try await repo.listar(trip, soloListas: true, limit: 200).isEmpty)

            let marcada = try await repo.marcarLista(id: "foto-a", en: trip)
            #expect(marcada == true)

            let listas = try await repo.listar(trip, soloListas: true, limit: 200)
            #expect(listas.map(\.id) == ["foto-a"])
            #expect(listas.first?.status == .ready)

            // La todavía-pending sigue fuera del filtro soloListas.
            let todas = try await repo.listar(trip, soloListas: false, limit: 200)
            #expect(todas.map(\.id) == ["foto-a", "foto-b"])
        }
    }

    @Test func marcarListaEsIdempotente() async throws {
        try await conRepo { repo, trip in
            let f = nuevaFoto("foto-idem", tripId: trip)
            try await repo.crearPendiente(f)

            #expect(try await repo.marcarLista(id: "foto-idem", en: trip) == true)
            // Segunda llamada sobre una foto ya `ready`: sigue devolviendo true (idempotente),
            // no un false engañoso.
            #expect(try await repo.marcarLista(id: "foto-idem", en: trip) == true)
            #expect(try await repo.foto(id: "foto-idem", en: trip)?.status == .ready)

            // No existe / trip equivocado -> false, sin fuga.
            #expect(try await repo.marcarLista(id: "no-existe", en: trip) == false)
            #expect(try await repo.marcarLista(id: "foto-idem", en: "otro-trip") == false)
        }
    }

    @Test func fotoPorIdScopeadaPorTrip() async throws {
        try await conRepo { repo, trip in
            let f = nuevaFoto("foto-scope", tripId: trip, caption: "playa")
            try await repo.crearPendiente(f)

            let leida = try await repo.foto(id: "foto-scope", en: trip)
            #expect(leida?.id == "foto-scope")
            #expect(leida?.caption == "playa")
            #expect(leida?.uploadedBy == ana)
            #expect(leida?.contentType == "image/jpeg")
            #expect(leida?.sizeBytes == 12345)
            #expect(leida?.status == .pending)

            // Otro tripId no ve la foto (scope por trip, sin fuga).
            #expect(try await repo.foto(id: "foto-scope", en: "otro-trip") == nil)
            #expect(try await repo.foto(id: "no-existe", en: trip) == nil)
        }
    }

    @Test func borrar() async throws {
        try await conRepo { repo, trip in
            let f = nuevaFoto("foto-borrar", tripId: trip)
            try await repo.crearPendiente(f)
            #expect(try await repo.foto(id: "foto-borrar", en: trip) != nil)

            try await repo.borrar(fotoId: "foto-borrar", en: trip)
            #expect(try await repo.foto(id: "foto-borrar", en: trip) == nil)

            let lista = try await repo.listar(trip, soloListas: false, limit: 200)
            #expect(!lista.contains { $0.id == "foto-borrar" })

            // Borrar algo que no existe es un no-op silencioso, sin lanzar.
            try await repo.borrar(fotoId: "no-existe", en: trip)
        }
    }

    // MARK: - Tope + orden estable

    /// `listar` respeta el `LIMIT` y el orden `(created_at, id)` es total: aquí las
    /// tres fotos comparten `created_at` a propósito, así que el desempate lo tiene que
    /// poner el `id`. Es el tope que más pesa del proyecto: cada foto devuelta cuesta
    /// una URL prefirmada contra el proveedor de storage.
    @Test func listarRespetaElLimitYDesempataPorId() async throws {
        try await conRepo { repo, trip in
            let mismoInstante = Date()
            let ids = ["foto-z-orden", "foto-a-orden", "foto-m-orden"]
            for id in ids {
                try await repo.crearPendiente(nuevaFoto(id, tripId: trip, createdAt: mismoInstante))
            }

            let completa = try await repo.listar(trip, soloListas: false, limit: 200).map(\.id)
            #expect(completa == ids.sorted(), "mismo created_at -> el orden lo fija el id")
            #expect(try await repo.listar(trip, soloListas: false, limit: 200).map(\.id) == completa)
            #expect(try await repo.listar(trip, soloListas: false, limit: 2).map(\.id) == Array(completa.prefix(2)))
            #expect(try await repo.listar(trip, soloListas: false, limit: 1).count == 1)

            // La rama `soloListas: true` es OTRA query: también lleva su LIMIT.
            for id in ids { #expect(try await repo.marcarLista(id: id, en: trip)) }
            #expect(try await repo.listar(trip, soloListas: true, limit: 2).map(\.id) == Array(completa.prefix(2)))
        }
    }
}
