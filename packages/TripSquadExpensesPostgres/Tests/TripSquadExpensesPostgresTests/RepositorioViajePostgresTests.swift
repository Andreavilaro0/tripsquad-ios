// Tests de integración del adaptador Postgres de ViajeRepositorio (ADR-0018).
// Mismo patrón que RepositorioPostgresTests.swift: se saltan si PG_TEST != "1"
// (local sin Docker); el CI la levanta como service container, aplica las
// migraciones de db/ y corre estos tests con PG_TEST=1.
//
// A diferencia de RepositorioPostgresTests.conRepo, aquí NO se siembra un viaje
// compartido: cada test crea el suyo vía `crearViaje` (es justo lo que se prueba).

import Foundation
import Testing
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadExpensesPostgres

@Suite("Adaptador Postgres de viajes (integración)", .enabled(if: pgHabilitado))
struct RepositorioViajePostgresTests {

    let ana = MiembroId("ana-viaje"), ivan = MiembroId("ivan-viaje")

    func conRepo(_ body: (RepositorioPostgres) async throws -> Void) async throws {
        let host = ProcessInfo.processInfo.environment["PG_TEST_HOST"] ?? "localhost"
        let config = PostgresClient.Configuration(
            host: host, port: 5432, username: "postgres", password: "postgres",
            database: "tripsquad", tls: .disable)
        let client = PostgresClient(configuration: config)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let repo = RepositorioPostgres(client: client)
            try await body(repo)
            group.cancelAll()
        }
    }

    /// Id único por viaje: `trips.id` es PK global, y los tests pueden correr en
    /// paralelo (mismo motivo que `nuevoId()` en RepositorioPostgresTests).
    func nuevoId() -> String { "trip-v-" + UUID().uuidString.prefix(8) }

    func invitar(_ repo: RepositorioPostgres, tripId: String, ahora: Date, vida: TimeInterval = 3600) async throws -> String {
        let code = "code-" + UUID().uuidString
        _ = try await repo.crearInvitacion(tripId: tripId, por: ana, code: code, expiresAt: ahora.addingTimeInterval(vida))
        return code
    }

    @Test func crearViajeDejaAlCreadorComoOwnerActivo() async throws {
        try await conRepo { repo in
            let ahora = Date()
            let id = nuevoId()
            let viaje = try await repo.crearViaje(id: id, name: "Roma", baseCurrency: "EUR", creador: ana, ahora: ahora)
            #expect(viaje.id == id)
            #expect(viaje.name == "Roma")
            #expect(viaje.closedAt == nil)
            #expect(try await repo.rol(de: ana, en: id) == .owner)
            let misViajes = try await repo.viajesDe(ana)
            #expect(misViajes.contains { $0.id == id })
        }
    }

    @Test func unirsePorCodigoFeliz() async throws {
        try await conRepo { repo in
            let ahora = Date()
            let id = nuevoId()
            _ = try await repo.crearViaje(id: id, name: "Roma", baseCurrency: "EUR", creador: ana, ahora: ahora)
            let code = try await invitar(repo, tripId: id, ahora: ahora)
            let r = try await repo.unirsePorCodigo(code: code, actor: ivan, ahora: ahora, tope: 50)
            #expect(r == .unido)
            #expect(try await repo.rol(de: ivan, en: id) == .member)
        }
    }

    @Test func unirsePorCodigoCaducado() async throws {
        try await conRepo { repo in
            let ahora = Date()
            let id = nuevoId()
            _ = try await repo.crearViaje(id: id, name: "Roma", baseCurrency: "EUR", creador: ana, ahora: ahora)
            let code = try await invitar(repo, tripId: id, ahora: ahora, vida: -1)
            let r = try await repo.unirsePorCodigo(code: code, actor: ivan, ahora: ahora, tope: 50)
            #expect(r == .caducado)
        }
    }

    @Test func unirsePorCodigoRevocado() async throws {
        try await conRepo { repo in
            let ahora = Date()
            let id = nuevoId()
            _ = try await repo.crearViaje(id: id, name: "Roma", baseCurrency: "EUR", creador: ana, ahora: ahora)
            let code = try await invitar(repo, tripId: id, ahora: ahora)
            let revocada = try await repo.revocarInvitacion(code: code, en: id, ahora: ahora)
            #expect(revocada)
            let r = try await repo.unirsePorCodigo(code: code, actor: ivan, ahora: ahora, tope: 50)
            #expect(r == .revocado)
        }
    }

    @Test func unirsePorCodigoConViajeCerrado() async throws {
        try await conRepo { repo in
            let ahora = Date()
            let id = nuevoId()
            _ = try await repo.crearViaje(id: id, name: "Roma", baseCurrency: "EUR", creador: ana, ahora: ahora)
            let code = try await invitar(repo, tripId: id, ahora: ahora)
            try await repo.cerrar(tripId: id, ahora: ahora)
            let r = try await repo.unirsePorCodigo(code: code, actor: ivan, ahora: ahora, tope: 50)
            #expect(r == .viajeCerrado)
        }
    }

    @Test func unirsePorCodigoYaMiembro() async throws {
        try await conRepo { repo in
            let ahora = Date()
            let id = nuevoId()
            _ = try await repo.crearViaje(id: id, name: "Roma", baseCurrency: "EUR", creador: ana, ahora: ahora)
            let code = try await invitar(repo, tripId: id, ahora: ahora)
            // ana ya es owner activo desde crearViaje.
            let r = try await repo.unirsePorCodigo(code: code, actor: ana, ahora: ahora, tope: 50)
            #expect(r == .yaMiembro)
        }
    }

    @Test func unirsePorCodigoLleno() async throws {
        try await conRepo { repo in
            let ahora = Date()
            let id = nuevoId()
            // Tope 1: el creador (owner) ya ocupa la única plaza.
            _ = try await repo.crearViaje(id: id, name: "Roma", baseCurrency: "EUR", creador: ana, ahora: ahora)
            let code = try await invitar(repo, tripId: id, ahora: ahora)
            let r = try await repo.unirsePorCodigo(code: code, actor: ivan, ahora: ahora, tope: 1)
            #expect(r == .lleno)
        }
    }

    @Test func quitarMiembroYReingresoReactivaLaFila() async throws {
        try await conRepo { repo in
            let ahora = Date()
            let id = nuevoId()
            _ = try await repo.crearViaje(id: id, name: "Roma", baseCurrency: "EUR", creador: ana, ahora: ahora)
            let code = try await invitar(repo, tripId: id, ahora: ahora)
            _ = try await repo.unirsePorCodigo(code: code, actor: ivan, ahora: ahora, tope: 50)
            #expect(try await repo.rol(de: ivan, en: id) == .member)

            try await repo.quitarMiembro(ivan, de: id, ahora: ahora)
            #expect(try await repo.rol(de: ivan, en: id) == nil)

            // Re-join: la fila existente (left_at != nil, PK trip_id+member_id) se
            // reactiva, no se duplica.
            let masTarde = ahora.addingTimeInterval(60)
            let r = try await repo.unirsePorCodigo(code: code, actor: ivan, ahora: masTarde, tope: 50)
            #expect(r == .unido)
            #expect(try await repo.rol(de: ivan, en: id) == .member)
            let activos = try await repo.miembros(de: id)
            #expect(activos.filter { $0.0 == ivan }.count == 1)
        }
    }
}
