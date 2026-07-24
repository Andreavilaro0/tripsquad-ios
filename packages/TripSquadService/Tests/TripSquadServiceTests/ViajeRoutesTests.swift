// Tests de los endpoints HTTP de onboarding (ADR-0018) contra el adaptador EN
// MEMORIA. El foco es la AUTORIZACIÓN: quién puede ver, invitar, expulsar, cerrar —
// exactamente igual que CasosDeUsoViajeTests, pero cruzando la frontera HTTP real
// (JWT firmado de verdad, router real, mapeo a status codes).

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Endpoints HTTP de onboarding (ADR-0018)")
struct ViajeRoutesTests {

    static let clave = ClaveDePrueba(kid: "test")
    func bearer(_ sub: String) async throws -> String { "Bearer \(try await firmar(Self.clave, sub: sub))" }

    /// Un `RepositorioEnMemoria` compartido por toda la app (brief §Tests HTTP).
    func app() async -> (any ApplicationProtocol, RepositorioEnMemoria) {
        let repo = RepositorioEnMemoria()
        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            casosViaje: CasosDeUsoViaje(repo: repo),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        return (Application(router: construirRouter(deps)), repo)
    }

    func crearViajeJSON(name: String = "Roma") -> ByteBuffer {
        ByteBuffer(string: #"{"name":"\#(name)"}"#)
    }

    // 1. POST /trips 201 -> GET /trips lo lista para el creador.
    @Test func crearViajeYListarlo() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var tripId = ""
            try await client.execute(
                uri: "/trips", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearViajeJSON()
            ) { res in
                #expect(res.status == .created)
                let body = String(buffer: res.body)
                #expect(body.contains("\"name\":\"Roma\""))
                #expect(body.contains("\"baseCurrency\":\"EUR\""))
                // extrae el id crudamente para el siguiente paso.
                if let r = body.range(of: #""id":""#) {
                    let rest = body[r.upperBound...]
                    tripId = String(rest.prefix(while: { $0 != "\"" }))
                }
            }
            #expect(!tripId.isEmpty)

            try await client.execute(
                uri: "/trips", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains(tripId))
            }
        }
    }

    // 2. GET /trips/:id por el creador 200 con members; por un NO-miembro -> 403
    //    (mismo 403 exista o no el viaje: brief §Tests HTTP #2).
    @Test func detalleSoloParaMiembros403SinFugaDeExistencia() async throws {
        let (app, repo) = await app()
        let viaje = try await repo.crearViaje(id: "t1", name: "Roma", baseCurrency: "EUR", creador: MiembroId("ana"), ahora: .now)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(viaje.id)", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"memberId\":\"ana\""))
            }

            try await client.execute(
                uri: "/trips/\(viaje.id)", method: .get,
                headers: [.authorization: try await bearer("sara")]
            ) { res in
                #expect(res.status == .forbidden)
            }

            // el mismo 403 para un tripId que directamente no existe (sin fuga).
            try await client.execute(
                uri: "/trips/no-existe", method: .get,
                headers: [.authorization: try await bearer("sara")]
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 3. POST invites por miembro 201; por no-miembro -> 403.
    @Test func invitarSoloMiembros() async throws {
        let (app, repo) = await app()
        let viaje = try await repo.crearViaje(id: "t1", name: "Roma", baseCurrency: "EUR", creador: MiembroId("ana"), ahora: .now)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(viaje.id)/invites", method: .post,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .created)
                let body = String(buffer: res.body)
                #expect(body.contains("\"code\""))
                #expect(body.contains("\"expiresAt\""))
            }

            try await client.execute(
                uri: "/trips/\(viaje.id)/invites", method: .post,
                headers: [.authorization: try await bearer("sara")]
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 4. Flujo join: A crea, A invita (code), B hace POST /trips/join {code} -> 200
    //    joined; GET /trips/:id ahora lista a B.
    @Test func flujoDeUnirsePorCodigo() async throws {
        let (app, repo) = await app()
        let viaje = try await repo.crearViaje(id: "t1", name: "Roma", baseCurrency: "EUR", creador: MiembroId("ana"), ahora: .now)
        let invitacion = try await repo.crearInvitacion(tripId: viaje.id, por: MiembroId("ana"), code: "c-1", expiresAt: .now.addingTimeInterval(3600))

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/join", method: .post,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"code":"\#(invitacion.code)"}"#)
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"result\":\"joined\""))
            }

            try await client.execute(
                uri: "/trips/\(viaje.id)", method: .get,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"memberId\":\"ivan\""))
            }

            // reintentar con el mismo code: ya es miembro.
            try await client.execute(
                uri: "/trips/join", method: .post,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"code":"\#(invitacion.code)"}"#)
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"result\":\"already_member\""))
            }
        }
    }

    // 5. join con code inventado -> 404; caducado/revocado -> 409.
    @Test func joinCodigoInvalidoCaducadoYRevocado() async throws {
        let (app, repo) = await app()
        let viaje = try await repo.crearViaje(id: "t1", name: "Roma", baseCurrency: "EUR", creador: MiembroId("ana"), ahora: .now)
        let caducada = try await repo.crearInvitacion(tripId: viaje.id, por: MiembroId("ana"), code: "c-caducado", expiresAt: Date(timeIntervalSince1970: 0))
        let revocada = try await repo.crearInvitacion(tripId: viaje.id, por: MiembroId("ana"), code: "c-revocado", expiresAt: .now.addingTimeInterval(3600))
        _ = try await repo.revocarInvitacion(code: revocada.code, en: viaje.id, ahora: .now)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/join", method: .post,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"code":"no-existe"}"#)
            ) { res in
                #expect(res.status == .notFound)
                #expect(String(buffer: res.body).contains("code_invalid"))
            }

            try await client.execute(
                uri: "/trips/join", method: .post,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"code":"\#(caducada.code)"}"#)
            ) { res in
                #expect(res.status == .conflict)
                #expect(String(buffer: res.body).contains("expired"))
            }

            try await client.execute(
                uri: "/trips/join", method: .post,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"code":"\#(revocada.code)"}"#)
            ) { res in
                #expect(res.status == .conflict)
                #expect(String(buffer: res.body).contains("revoked"))
            }
        }
    }

    // 6. DELETE members: B se sale a sí mismo -> 204; un member intentando expulsar
    //    a otro -> 403; owner expulsa a B -> 204.
    @Test func salirYExpulsarAutorizacion() async throws {
        let (app, repo) = await app()
        let viaje = try await repo.crearViaje(id: "t1", name: "Roma", baseCurrency: "EUR", creador: MiembroId("ana"), ahora: .now)
        _ = try await repo.unirsePorCodigo(
            code: try await repo.crearInvitacion(tripId: viaje.id, por: MiembroId("ana"), code: "c1", expiresAt: .now.addingTimeInterval(3600)).code,
            actor: MiembroId("ivan"), ahora: .now, tope: 50)
        _ = try await repo.unirsePorCodigo(code: "c1", actor: MiembroId("sara"), ahora: .now, tope: 50)

        try await app.test(.router) { client in
            // ivan (member) intenta expulsar a sara (member) -> 403.
            try await client.execute(
                uri: "/trips/\(viaje.id)/members/sara", method: .delete,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .forbidden)
            }

            // ivan se sale a sí mismo -> 204.
            try await client.execute(
                uri: "/trips/\(viaje.id)/members/ivan", method: .delete,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .noContent)
            }

            // ana (owner) expulsa a sara -> 204.
            try await client.execute(
                uri: "/trips/\(viaje.id)/members/sara", method: .delete,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .noContent)
            }
        }
    }

    // 7. POST close por owner 200; por member -> 403.
    @Test func cerrarSoloOwner() async throws {
        let (app, repo) = await app()
        let viaje = try await repo.crearViaje(id: "t1", name: "Roma", baseCurrency: "EUR", creador: MiembroId("ana"), ahora: .now)
        _ = try await repo.unirsePorCodigo(
            code: try await repo.crearInvitacion(tripId: viaje.id, por: MiembroId("ana"), code: "c1", expiresAt: .now.addingTimeInterval(3600)).code,
            actor: MiembroId("ivan"), ahora: .now, tope: 50)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(viaje.id)/close", method: .post,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .forbidden)
            }

            try await client.execute(
                uri: "/trips/\(viaje.id)/close", method: .post,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"closed\":true"))
            }
        }
    }

    // Extra: sin token, 401 (misma frontera de auth que gastos/settle).
    @Test func sinTokenTrips401() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips", method: .get) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
