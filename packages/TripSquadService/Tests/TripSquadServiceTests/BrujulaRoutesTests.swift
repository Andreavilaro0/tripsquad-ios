// Tests de los endpoints HTTP de la Brújula IA (M8, ADR-0023 borrador) contra
// el adaptador EN MEMORIA. El foco es la AUTORIZACIÓN — mismo espíritu que
// ChatRoutesTests/ItinerarioRoutesTests, cruzando la frontera HTTP real (JWT
// firmado de verdad, router real, mapeo a status codes).

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Endpoints HTTP de la brújula IA (M8, ADR-0023 borrador)")
struct BrujulaRoutesTests {
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
            casosVotacion: CasosDeUsoVotacion(repo: repo, membresia: repo, viajes: repo),
            casosItinerario: CasosDeUsoItinerario(repo: repo, membresia: repo, viajes: repo),
            casosChat: CasosDeUsoChat(repo: repo, membresia: repo),
            casosFoto: CasosDeUsoFoto(repo: repo, membresia: repo, viajes: repo, storage: FotoStorageStub()),
            casosBrujula: CasosDeUsoBrujula(repo: repo, membresia: repo, asistente: AsistenteStub()),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        return (Application(router: construirRouter(deps)), repo)
    }

    func queryJSON(_ query: String) -> ByteBuffer {
        ByteBuffer(string: #"{"query":"\#(query)"}"#)
    }

    // 1. Consultar por miembro -> 200 con el marcador del stub en la respuesta.
    @Test func consultarPorMiembroOK() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/brujula", method: .post,
                headers: [.authorization: try await bearer("ana")], body: queryJSON("¿quién debe qué?")
            ) { res in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.contains("[brújula-stub]"))
                #expect(body.contains("todo saldado"))
            }
        }
    }

    // 2. No-miembro no consulta -> 403 sin fuga.
    @Test func noMiembroNoConsulta403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/brujula", method: .post,
                headers: [.authorization: try await bearer("sara")], body: queryJSON("¿quién debe qué?")
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 3. Query vacía -> 422 reglaViolada.
    @Test func queryVacia422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/brujula", method: .post,
                headers: [.authorization: try await bearer("ana")], body: queryJSON("")
            ) { res in
                #expect(res.status.code == 422)
                let body = String(buffer: res.body)
                #expect(body.contains("query_vacia"))
            }
        }
    }

    // 4. Query demasiado larga (>500 chars) -> 422 reglaViolada.
    @Test func queryMuyLarga422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let queryLarga = String(repeating: "a", count: 501)
            try await client.execute(
                uri: "/trips/\(trip)/brujula", method: .post,
                headers: [.authorization: try await bearer("ana")], body: queryJSON(queryLarga)
            ) { res in
                #expect(res.status.code == 422)
                let body = String(buffer: res.body)
                #expect(body.contains("query_muy_larga"))
            }
        }
    }

    // Extra: sin token, 401 (misma frontera de auth que gastos/settle/trips/polls/chat).
    @Test func sinTokenBrujula401() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/brujula", method: .post, body: queryJSON("hola")
            ) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
