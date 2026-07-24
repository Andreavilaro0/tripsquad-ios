// Tests de los endpoints HTTP de chat (M6, ADR-0021 borrador) contra el
// adaptador EN MEMORIA. El foco es la AUTORIZACIÓN — mismo espíritu que
// ItinerarioRoutesTests/VotacionRoutesTests, cruzando la frontera HTTP real
// (JWT firmado de verdad, router real, mapeo a status codes).

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Endpoints HTTP de chat (M6, ADR-0021 borrador)")
struct ChatRoutesTests {
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
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        return (Application(router: construirRouter(deps)), repo)
    }

    func mensajeJSON(_ body: String = "Hola squad") -> ByteBuffer {
        ByteBuffer(string: #"{"body":"\#(body)"}"#)
    }

    /// Extrae crudamente el `"id":...` (número, sin comillas) del primer match del body.
    func idDe(_ body: String) -> String {
        guard let r = body.range(of: #""id":"#) else { return "" }
        let rest = body[r.upperBound...]
        return String(rest.prefix(while: { $0 != "," && $0 != "}" }))
    }

    // 1. POST enviar por miembro -> 201; GET listar por miembro -> 200 con el mensaje.
    @Test func enviarYListarPorMiembro() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var msgId = ""
            try await client.execute(
                uri: "/trips/\(trip)/messages", method: .post,
                headers: [.authorization: try await bearer("ana")], body: mensajeJSON("Hola squad")
            ) { res in
                #expect(res.status == .created)
                let body = String(buffer: res.body)
                #expect(body.contains("\"author\":\"ana\""))
                #expect(body.contains("\"body\":\"Hola squad\""))
                msgId = idDe(body)
            }
            #expect(!msgId.isEmpty)

            try await client.execute(
                uri: "/trips/\(trip)/messages", method: .get,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.contains("\"body\":\"Hola squad\""))
                #expect(body.contains("\"deleted\":false"))
                #expect(body.contains("\"nextSince\":\(msgId)"))
            }
        }
    }

    // 2. No-miembro no envía ni lista -> 403 (sin fuga).
    @Test func noMiembroNoEnviaNiLista403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/messages", method: .post,
                headers: [.authorization: try await bearer("sara")], body: mensajeJSON()
            ) { res in
                #expect(res.status == .forbidden)
            }

            try await client.execute(
                uri: "/trips/\(trip)/messages", method: .get,
                headers: [.authorization: try await bearer("sara")]
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 3. Listar respeta since/limit: con since=id del primer mensaje, el
    // segundo GET solo devuelve los mensajes posteriores.
    @Test func listarRespetaSinceYLimit() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var primerId = ""
            try await client.execute(
                uri: "/trips/\(trip)/messages", method: .post,
                headers: [.authorization: try await bearer("ana")], body: mensajeJSON("primero")
            ) { res in primerId = idDe(String(buffer: res.body)) }

            try await client.execute(
                uri: "/trips/\(trip)/messages", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: mensajeJSON("segundo")
            ) { res in #expect(res.status == .created) }

            // Sin since: los dos mensajes, en orden cronológico.
            try await client.execute(
                uri: "/trips/\(trip)/messages", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                let body = String(buffer: res.body)
                #expect(body.contains("primero"))
                #expect(body.contains("segundo"))
            }

            // since=primerId: solo el segundo.
            try await client.execute(
                uri: "/trips/\(trip)/messages?since=\(primerId)", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                let body = String(buffer: res.body)
                #expect(!body.contains("primero"))
                #expect(body.contains("segundo"))
            }

            // limit=1 sin since: solo el primero (orden cronológico, clamp lo hace el dominio).
            try await client.execute(
                uri: "/trips/\(trip)/messages?limit=1", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                let body = String(buffer: res.body)
                #expect(body.contains("primero"))
                #expect(!body.contains("segundo"))
            }
        }
    }

    // 4. Borrar por el autor -> 204; el mensaje aparece en la lista con marcador.
    @Test func borrarPorAutorOKyMarcadorEnLista() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var msgId = ""
            try await client.execute(
                uri: "/trips/\(trip)/messages", method: .post,
                headers: [.authorization: try await bearer("ana")], body: mensajeJSON("borrame")
            ) { res in msgId = idDe(String(buffer: res.body)) }

            try await client.execute(
                uri: "/trips/\(trip)/messages/\(msgId)", method: .delete,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .noContent)
            }

            try await client.execute(
                uri: "/trips/\(trip)/messages", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                let body = String(buffer: res.body)
                #expect(!body.contains("borrame"))
                #expect(body.contains("\"deleted\":true"))
                #expect(body.contains("[mensaje eliminado]"))
            }
        }
    }

    // 5. Borrar por otro miembro (no autor) -> 403.
    @Test func borrarPorOtroMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var msgId = ""
            // ana envía; ivan es solo miembro.
            try await client.execute(
                uri: "/trips/\(trip)/messages", method: .post,
                headers: [.authorization: try await bearer("ana")], body: mensajeJSON()
            ) { res in msgId = idDe(String(buffer: res.body)) }

            try await client.execute(
                uri: "/trips/\(trip)/messages/\(msgId)", method: .delete,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // Extra: sin token, 401 (misma frontera de auth que gastos/settle/trips/polls/itinerary).
    @Test func sinTokenMessages401() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/messages", method: .get) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
