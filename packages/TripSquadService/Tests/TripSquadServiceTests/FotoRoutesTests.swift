// Tests de los endpoints HTTP de fotos (M7 Task 3, ADR-0022 borrador —
// docs/design/fotos-plan-stub.md) contra el adaptador EN MEMORIA. El foco es
// la AUTORIZACIÓN — mismo espíritu que ChatRoutesTests/ItinerarioRoutesTests,
// cruzando la frontera HTTP real (JWT firmado de verdad, router real, mapeo a
// status codes).
//
// NOTA sobre el repo en memoria (ver ItinerarioRoutesTests): `Membresia`
// (almacén `miembros`, via `anadirMiembro`) y `ViajeRepositorio.rol` (almacén
// `miembrosDeViaje`, via `crearViaje`/`unirsePorCodigo`) son DOS almacenes
// separados. Los tests que solo necesitan presign/confirmar/listar usan
// `anadirMiembro`; el test de borrar por owner necesita además `crearViaje`
// para que `rol` devuelva `.owner` de verdad.

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Endpoints HTTP de fotos (M7 Task 3, ADR-0022 borrador)")
struct FotoRoutesTests {
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
            casosReserva: CasosDeUsoReserva(repo: repo, itinerario: repo, membresia: repo, viajes: repo),
            casosChat: CasosDeUsoChat(repo: repo, membresia: repo),
            casosFoto: CasosDeUsoFoto(repo: repo, membresia: repo, viajes: repo, storage: FotoStorageStub()),
            casosBrujula: CasosDeUsoBrujula(repo: repo, membresia: repo, settlements: repo, asistente: AsistenteStub()),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        return (Application(router: construirRouter(deps)), repo)
    }

    func presignJSON(contentType: String = "image/jpeg", sizeBytes: Int64? = 1024, caption: String? = nil) -> ByteBuffer {
        let sz = sizeBytes.map { "\($0)" } ?? "null"
        let cap = caption.map { #","caption":"\#($0)""# } ?? ""
        return ByteBuffer(string: #"{"contentType":"\#(contentType)","sizeBytes":\#(sz)\#(cap)}"#)
    }

    /// Extrae crudamente el `"campo":"..."` del primer match del body.
    /// `JSONEncoder` escapa `/` como `\/` en la salida — se desescapa aquí
    /// para que comparar contra "stub://..." funcione literal.
    func campoDe(_ body: String, _ campo: String) -> String {
        guard let r = body.range(of: #""\#(campo)":""#) else { return "" }
        let rest = body[r.upperBound...]
        let crudo = String(rest.prefix(while: { $0 != "\"" }))
        return crudo.replacingOccurrences(of: "\\/", with: "/")
    }

    // 1. presign por miembro -> 201, uploadUrl empieza por "stub://".
    @Test func presignPorMiembro201ConUrlStub() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/photos/presign", method: .post,
                headers: [.authorization: try await bearer("ana")], body: presignJSON()
            ) { res in
                #expect(res.status == .created)
                let body = String(buffer: res.body)
                #expect(!campoDe(body, "photoId").isEmpty)
                #expect(campoDe(body, "uploadUrl").hasPrefix("stub://"))
            }
        }
    }

    // 2. presign con content-type inválido -> 422.
    @Test func presignConContentTypeInvalido422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/photos/presign", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: presignJSON(contentType: "application/pdf")
            ) { res in
                #expect(res.status.code == 422)
                #expect(String(buffer: res.body).contains("content_type_invalido"))
            }
        }
    }

    // 3. no-miembro no presign ni lista -> 403 sin fuga.
    @Test func noMiembroNoPresignNiLista403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/photos/presign", method: .post,
                headers: [.authorization: try await bearer("sara")], body: presignJSON()
            ) { res in
                #expect(res.status == .forbidden)
            }

            try await client.execute(
                uri: "/trips/\(trip)/photos", method: .get,
                headers: [.authorization: try await bearer("sara")]
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 4. confirmar marca ready; listar solo devuelve fotos ready con url.
    @Test func confirmarMarcaReadyYListarSoloReadyConUrl() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var pendienteId = ""
            var listaId = ""

            try await client.execute(
                uri: "/trips/\(trip)/photos/presign", method: .post,
                headers: [.authorization: try await bearer("ana")], body: presignJSON()
            ) { res in pendienteId = campoDe(String(buffer: res.body), "photoId") }

            try await client.execute(
                uri: "/trips/\(trip)/photos/presign", method: .post,
                headers: [.authorization: try await bearer("ana")], body: presignJSON(contentType: "image/png")
            ) { res in listaId = campoDe(String(buffer: res.body), "photoId") }

            // Antes de confirmar, no aparece ninguna.
            try await client.execute(
                uri: "/trips/\(trip)/photos", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                #expect(!String(buffer: res.body).contains(listaId))
            }

            try await client.execute(
                uri: "/trips/\(trip)/photos/\(listaId)/confirm", method: .post,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"status\":\"ready\""))
            }

            try await client.execute(
                uri: "/trips/\(trip)/photos", method: .get,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.contains(listaId))
                #expect(!body.contains(pendienteId))
                #expect(campoDe(body, "url").hasPrefix("stub://"))
            }
        }
    }

    // 5. borrar por el subidor -> 204.
    @Test func borrarPorSubidor204() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var photoId = ""
            try await client.execute(
                uri: "/trips/\(trip)/photos/presign", method: .post,
                headers: [.authorization: try await bearer("ana")], body: presignJSON()
            ) { res in photoId = campoDe(String(buffer: res.body), "photoId") }

            try await client.execute(
                uri: "/trips/\(trip)/photos/\(photoId)", method: .delete,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .noContent)
            }
        }
    }

    // 6. borrar por otro miembro (ni subidor ni owner) -> 403.
    @Test func borrarPorOtroMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var photoId = ""
            try await client.execute(
                uri: "/trips/\(trip)/photos/presign", method: .post,
                headers: [.authorization: try await bearer("ana")], body: presignJSON()
            ) { res in photoId = campoDe(String(buffer: res.body), "photoId") }

            try await client.execute(
                uri: "/trips/\(trip)/photos/\(photoId)", method: .delete,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 7. borrar por el owner del viaje (no subidor) -> 204.
    @Test func borrarPorOwner204() async throws {
        let repo = RepositorioEnMemoria()
        let viaje = try await repo.crearViaje(id: "t-owner", name: "Roma", baseCurrency: "EUR", creador: MiembroId("ana"), ahora: .now)
        let invitacion = try await repo.crearInvitacion(tripId: viaje.id, por: MiembroId("ana"), code: "c1", expiresAt: .now.addingTimeInterval(3600))
        _ = try await repo.unirsePorCodigo(code: invitacion.code, actor: MiembroId("ivan"), ahora: .now, tope: 50)
        for m in [MiembroId("ana"), MiembroId("ivan")] { await repo.anadirMiembro(m, a: viaje.id) }

        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            casosViaje: CasosDeUsoViaje(repo: repo),
            casosVotacion: CasosDeUsoVotacion(repo: repo, membresia: repo, viajes: repo),
            casosItinerario: CasosDeUsoItinerario(repo: repo, membresia: repo, viajes: repo),
            casosReserva: CasosDeUsoReserva(repo: repo, itinerario: repo, membresia: repo, viajes: repo),
            casosChat: CasosDeUsoChat(repo: repo, membresia: repo),
            casosFoto: CasosDeUsoFoto(repo: repo, membresia: repo, viajes: repo, storage: FotoStorageStub()),
            casosBrujula: CasosDeUsoBrujula(repo: repo, membresia: repo, settlements: repo, asistente: AsistenteStub()),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        let app = Application(router: construirRouter(deps))

        try await app.test(.router) { client in
            var photoId = ""
            // ivan (member, no owner) sube -> él es el subidor.
            try await client.execute(
                uri: "/trips/\(viaje.id)/photos/presign", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: presignJSON()
            ) { res in photoId = campoDe(String(buffer: res.body), "photoId") }

            // ana (owner, no subidora) SÍ puede borrar.
            try await client.execute(
                uri: "/trips/\(viaje.id)/photos/\(photoId)", method: .delete,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .noContent)
            }
        }
    }

    // Extra: sin token, 401 (misma frontera de auth que gastos/settle/trips/polls/itinerary/chat).
    @Test func sinTokenPhotos401() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/photos", method: .get) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    /// GET /trips/:id/photos?limit= — el tope llega desde el query, y un `limit` basura
    /// NO se rechaza con 4xx (mismo criterio que ChatRoutes). Aquí el tope es además el
    /// que acota las URLs prefirmadas: una por foto DEVUELTA.
    @Test func limitDelQuerySeAplicaYUnValorInvalidoNoEs4xx() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            for _ in 0..<3 {
                var fotoId = ""
                try await client.execute(
                    uri: "/trips/\(trip)/photos/presign", method: .post,
                    headers: [.authorization: try await bearer("ana")], body: presignJSON()
                ) { res in
                    #expect(res.status == .created)
                    fotoId = campoDe(String(buffer: res.body), "photoId")
                }
                try await client.execute(
                    uri: "/trips/\(trip)/photos/\(fotoId)/confirm", method: .post,
                    headers: [.authorization: try await bearer("ana")]
                ) { res in #expect(res.status == .ok) }
            }

            try await client.execute(
                uri: "/trips/\(trip)/photos?limit=1", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                #expect(contarOcurrencias(String(buffer: res.body), de: "\"url\":") == 1)
            }
            for basura in ["abc", "0", "-1", ""] {
                try await client.execute(
                    uri: "/trips/\(trip)/photos?limit=\(basura)", method: .get,
                    headers: [.authorization: try await bearer("ana")]
                ) { res in
                    #expect(res.status == .ok, "limit='\(basura)' no debe dar 4xx")
                }
            }
            try await client.execute(
                uri: "/trips/\(trip)/photos", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(contarOcurrencias(String(buffer: res.body), de: "\"url\":") == 3)
            }
        }
    }
}
