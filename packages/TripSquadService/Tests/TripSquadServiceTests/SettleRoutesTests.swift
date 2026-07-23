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
}
