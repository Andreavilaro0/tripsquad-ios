import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

// El POST /settlements se retiró hasta el flujo de confirmación (ADR-0017 en curso).
// Aquí solo queda el GET suggestion. La idempotencia/dedupe de la escritura sigue
// cubierta a nivel de dominio en CasosDeUsoSettleTests (paquete TripSquadExpenses).
@Suite("Endpoints :settle — GET suggestion (ADR-0016 a)")
struct SettleRoutesTests {
    let trip = "trip-1"
    static let clave = ClaveDePrueba(kid: "test")
    func bearer(_ sub: String) async throws -> String { "Bearer \(try await firmar(Self.clave, sub: sub))" }

    func app() async -> (any ApplicationProtocol, RepositorioEnMemoria) {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(MiembroId("ana"), a: trip)
        await repo.anadirMiembro(MiembroId("ivan"), a: trip)
        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            casosViaje: CasosDeUsoViaje(repo: repo),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        return (Application(router: construirRouter(deps)), repo)
    }

    @Test func sugerenciaGET200() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlement/suggestion", method: .get,
                headers: [.authorization: try await bearer("ana")]) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("transfers"))
            }
        }
    }

    @Test func sugerenciaNoMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlement/suggestion", method: .get,
                headers: [.authorization: try await bearer("sara")]) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // Finding D (revisión multi-modelo): la autorización va ANTES de leer gastos. Este repo
    // dice "no miembro" y LANZA en gastos(): si el orden fuese al revés, gastos() explotaría
    // y el cliente vería 5xx. Debe ver 403.
    @Test func noMiembroNoLlegaALeerGastos403() async throws {
        let repo = RepoNoMiembroQueLanzaEnGastos()
        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            // RepoNoMiembroQueLanzaEnGastos no conforma ViajeRepositorio y este test
            // no ejercita /trips: un repo en memoria aparte basta.
            casosViaje: CasosDeUsoViaje(repo: RepositorioEnMemoria()),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        let app = Application(router: construirRouter(deps))
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlement/suggestion", method: .get,
                headers: [.authorization: try await bearer("sara")]) { res in
                #expect(res.status == .forbidden)   // 403, no 5xx: la authz cortó antes de gastos()
            }
        }
    }
}

/// Repo de prueba para el finding D: NO miembro, y `gastos()` LANZA. Sirve para verificar
/// que la ruta autoriza antes de tocar gastos. El resto de métodos no se ejercitan aquí.
private struct RepoNoMiembroQueLanzaEnGastos: GastoRepositorio, Membresia, SettlementRepositorio {
    struct Boom: Error {}
    func esMiembro(_ miembro: MiembroId, de tripId: String) async throws -> Bool { false }
    func viajeCerrado(_ tripId: String) async throws -> Bool { false }
    func gastos(de tripId: String) async throws -> [GastoConEtag] { throw Boom() }
    func respuestaPrevia(actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura? { throw Boom() }
    func guardar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura { throw Boom() }
    func gasto(id: String, en tripId: String) async throws -> GastoConEtag? { throw Boom() }
    func actualizar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura { throw Boom() }
    func eliminar(id: String, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura { throw Boom() }
    func registrar(_ settlement: Settlement) async throws -> ResultadoSettle { throw Boom() }
}
