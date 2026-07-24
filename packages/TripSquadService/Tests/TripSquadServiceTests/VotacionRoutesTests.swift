// Tests de los endpoints HTTP de votaciones (M4, ADR-0019 borrador) contra el
// adaptador EN MEMORIA. El foco es la AUTORIZACIÓN — mismo espíritu que
// ViajeRoutesTests, cruzando la frontera HTTP real (JWT firmado de verdad,
// router real, mapeo a status codes).
//
// NOTA sobre el repo en memoria (ver CasosDeUsoVotacionTests): `Membresia`
// (almacén `miembros`, via `anadirMiembro`) y `ViajeRepositorio.rol` (almacén
// `miembrosDeViaje`, via `crearViaje`/`unirsePorCodigo`) son DOS almacenes
// separados. Los tests que solo necesitan ver/crear/votar usan `anadirMiembro`;
// el test de cierre por owner necesita además `crearViaje` para que `rol`
// devuelva `.owner` de verdad.

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Endpoints HTTP de votaciones (M4, ADR-0019 borrador)")
struct VotacionRoutesTests {
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

    func crearPollJSON(question: String = "¿Playa o montaña?", options: [String] = ["playa", "montaña"]) -> ByteBuffer {
        let opts = options.map { #""\#($0)""# }.joined(separator: ",")
        return ByteBuffer(string: #"{"question":"\#(question)","options":[\#(opts)]}"#)
    }

    /// Extrae crudamente el `"id":"..."` del primer match del body (mismo truco que ViajeRoutesTests).
    func idDe(_ body: String) -> String {
        guard let r = body.range(of: #""id":""#) else { return "" }
        let rest = body[r.upperBound...]
        return String(rest.prefix(while: { $0 != "\"" }))
    }

    // 1. POST crear por miembro -> 201; GET listar por miembro -> 200 con la poll.
    @Test func crearYListarPorMiembro() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var pollId = ""
            try await client.execute(
                uri: "/trips/\(trip)/polls", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearPollJSON()
            ) { res in
                #expect(res.status == .created)
                let body = String(buffer: res.body)
                #expect(body.contains("\"question\":\"¿Playa o montaña?\""))
                #expect(body.contains("\"closed\":false"))
                pollId = idDe(body)
            }
            #expect(!pollId.isEmpty)

            try await client.execute(
                uri: "/trips/\(trip)/polls", method: .get,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains(pollId))
            }
        }
    }

    // 2. No-miembro no crea ni lista -> 403.
    @Test func noMiembroNoCreaNiListaNiVe403() async throws {
        let (app, repo) = await app()
        let ahora = Date()
        guard case .success(let v) = try await CasosDeUsoVotacion(repo: repo, membresia: repo, viajes: repo)
            .crear(tripId: trip, question: "q", options: ["a", "b"], actor: MiembroId("ana"), ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/polls", method: .post,
                headers: [.authorization: try await bearer("sara")], body: crearPollJSON()
            ) { res in
                #expect(res.status == .forbidden)
            }

            try await client.execute(
                uri: "/trips/\(trip)/polls", method: .get,
                headers: [.authorization: try await bearer("sara")]
            ) { res in
                #expect(res.status == .forbidden)
            }

            try await client.execute(
                uri: "/trips/\(trip)/polls/\(v.id)", method: .get,
                headers: [.authorization: try await bearer("sara")]
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 3. Votar feliz + cambiar voto (UPSERT, no duplica) + GET detalle con conteos y votantes.
    @Test func votarFelizYCambiarVotoConDetalle() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var pollId = ""
            try await client.execute(
                uri: "/trips/\(trip)/polls", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearPollJSON()
            ) { res in pollId = idDe(String(buffer: res.body)) }

            try await client.execute(
                uri: "/trips/\(trip)/polls/\(pollId)/vote", method: .post,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"choice":"playa"}"#)
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"result\":\"registered\""))
            }

            // cambia de opción -> sigue siendo 200, no duplica.
            try await client.execute(
                uri: "/trips/\(trip)/polls/\(pollId)/vote", method: .post,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"choice":"montaña"}"#)
            ) { res in
                #expect(res.status == .ok)
            }

            try await client.execute(
                uri: "/trips/\(trip)/polls/\(pollId)", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.contains("\"playa\":0"))
                #expect(body.contains("\"montaña\":1"))
                #expect(body.contains("\"memberId\":\"ivan\""))
                #expect(body.contains("\"choice\":\"montaña\""))
            }
        }
    }

    // 4. Votar una option inválida -> 422 con code invalid_option.
    @Test func votarOptionInvalida422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var pollId = ""
            try await client.execute(
                uri: "/trips/\(trip)/polls", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearPollJSON()
            ) { res in pollId = idDe(String(buffer: res.body)) }

            try await client.execute(
                uri: "/trips/\(trip)/polls/\(pollId)/vote", method: .post,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"choice":"no-existe"}"#)
            ) { res in
                #expect(res.status.code == 422)
                #expect(String(buffer: res.body).contains("invalid_option"))
            }
        }
    }

    // 5. Votar en una votación cerrada -> 422 con code poll_closed.
    @Test func votarEnCerrada422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var pollId = ""
            try await client.execute(
                uri: "/trips/\(trip)/polls", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearPollJSON()
            ) { res in pollId = idDe(String(buffer: res.body)) }

            try await client.execute(
                uri: "/trips/\(trip)/polls/\(pollId)/close", method: .post,
                headers: [.authorization: try await bearer("ana")]
            ) { res in #expect(res.status == .ok) }

            try await client.execute(
                uri: "/trips/\(trip)/polls/\(pollId)/vote", method: .post,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"choice":"playa"}"#)
            ) { res in
                #expect(res.status.code == 422)
                #expect(String(buffer: res.body).contains("poll_closed"))
            }
        }
    }

    // 6. Solo el creador de la poll o el owner del viaje cierran; otro member -> 403.
    @Test func soloCreadorUOwnerCierran403ParaOtroMiembro() async throws {
        let (app, repo) = await app()
        // Necesita el almacén de onboarding real (crearViaje + unirse) para que
        // `rol` funcione — ver nota de cabecera.
        let viaje = try await repo.crearViaje(id: "t-owner", name: "Roma", baseCurrency: "EUR", creador: MiembroId("ana"), ahora: .now)
        let invitacion = try await repo.crearInvitacion(tripId: viaje.id, por: MiembroId("ana"), code: "c1", expiresAt: .now.addingTimeInterval(3600))
        _ = try await repo.unirsePorCodigo(code: invitacion.code, actor: MiembroId("ivan"), ahora: .now, tope: 50)
        _ = try await repo.unirsePorCodigo(code: invitacion.code, actor: MiembroId("sara"), ahora: .now, tope: 50)
        for m in [MiembroId("ana"), MiembroId("ivan"), MiembroId("sara")] { await repo.anadirMiembro(m, a: viaje.id) }

        try await app.test(.router) { client in
            var pollId = ""
            // ivan (member, no owner) crea -> es el creador de la poll.
            try await client.execute(
                uri: "/trips/\(viaje.id)/polls", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: crearPollJSON()
            ) { res in pollId = idDe(String(buffer: res.body)) }

            // sara (ni creadora ni owner) intenta cerrar -> 403.
            try await client.execute(
                uri: "/trips/\(viaje.id)/polls/\(pollId)/close", method: .post,
                headers: [.authorization: try await bearer("sara")]
            ) { res in #expect(res.status == .forbidden) }

            // ana (owner, no creadora) SÍ puede cerrar.
            try await client.execute(
                uri: "/trips/\(viaje.id)/polls/\(pollId)/close", method: .post,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"closed\":true"))
            }
        }
    }

    // Extra: sin token, 401 (misma frontera de auth que gastos/settle/trips).
    @Test func sinTokenPolls401() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/polls", method: .get) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
