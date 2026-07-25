// Tests de los endpoints HTTP de itinerario (M5, ADR-0020 borrador) contra el
// adaptador EN MEMORIA. El foco es la AUTORIZACIÓN — mismo espíritu que
// VotacionRoutesTests, cruzando la frontera HTTP real (JWT firmado de verdad,
// router real, mapeo a status codes).
//
// NOTA sobre el repo en memoria (ver VotacionRoutesTests): `Membresia` (almacén
// `miembros`, via `anadirMiembro`) y `ViajeRepositorio.rol` (almacén
// `miembrosDeViaje`, via `crearViaje`/`unirsePorCodigo`) son DOS almacenes
// separados. Los tests que solo necesitan crear/listar/ver usan `anadirMiembro`;
// los tests de editar/borrar por owner necesitan además `crearViaje` para que
// `rol` devuelva `.owner` de verdad.

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Endpoints HTTP de itinerario (M5, ADR-0020 borrador)")
struct ItinerarioRoutesTests {
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

    func crearItemJSON(title: String = "Coliseo", day: String = "2026-08-02", startTime: String? = "10:00") -> ByteBuffer {
        let st = startTime.map { #","startTime":"\#($0)""# } ?? ""
        return ByteBuffer(string: #"{"title":"\#(title)","day":"\#(day)"\#(st)}"#)
    }

    /// Extrae crudamente el `"id":"..."` del primer match del body (mismo truco que VotacionRoutesTests).
    func idDe(_ body: String) -> String {
        guard let r = body.range(of: #""id":""#) else { return "" }
        let rest = body[r.upperBound...]
        return String(rest.prefix(while: { $0 != "\"" }))
    }

    // 1. POST crear por miembro -> 201; GET listar por miembro -> 200 con el item.
    @Test func crearYListarPorMiembro() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var itemId = ""
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearItemJSON()
            ) { res in
                #expect(res.status == .created)
                let body = String(buffer: res.body)
                #expect(body.contains("\"title\":\"Coliseo\""))
                #expect(body.contains("\"day\":\"2026-08-02\""))
                itemId = idDe(body)
            }
            #expect(!itemId.isEmpty)

            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .get,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains(itemId))
            }
        }
    }

    // 2. No-miembro no crea ni lista -> 403 (sin fuga).
    @Test func noMiembroNoCreaNiLista403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .post,
                headers: [.authorization: try await bearer("sara")], body: crearItemJSON()
            ) { res in
                #expect(res.status == .forbidden)
            }

            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .get,
                headers: [.authorization: try await bearer("sara")]
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 3. Editar por el creador -> 200 con los campos actualizados.
    @Test func editarPorCreadorOK() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var itemId = ""
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearItemJSON()
            ) { res in itemId = idDe(String(buffer: res.body)) }

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)", method: .patch,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"title":"Coliseo (cambiado)"}"#)
            ) { res in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.contains("\"title\":\"Coliseo (cambiado)\""))
                // PATCH parcial: day no enviado, conserva el valor original.
                #expect(body.contains("\"day\":\"2026-08-02\""))
            }
        }
    }

    // 4. Borrar por el creador -> 204.
    @Test func borrarPorCreadorOK() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var itemId = ""
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearItemJSON()
            ) { res in itemId = idDe(String(buffer: res.body)) }

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)", method: .delete,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .noContent)
            }

            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(!String(buffer: res.body).contains(itemId))
            }
        }
    }

    // 5. Editar/borrar por otro miembro (ni creador ni owner) -> 403.
    @Test func editarYBorrarPorOtroMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var itemId = ""
            // ana crea (es la creadora); ivan es solo miembro.
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearItemJSON()
            ) { res in itemId = idDe(String(buffer: res.body)) }

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)", method: .patch,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"title":"Hackeado"}"#)
            ) { res in
                #expect(res.status == .forbidden)
            }

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)", method: .delete,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 6. El owner del viaje (no creador de la actividad) SÍ puede editar/borrar.
    @Test func ownerPuedeEditarYBorrarAunqueNoSeaCreador() async throws {
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
            var itemId = ""
            // ivan (member, no owner) crea -> es el creador de la actividad.
            try await client.execute(
                uri: "/trips/\(viaje.id)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: crearItemJSON()
            ) { res in itemId = idDe(String(buffer: res.body)) }

            // ana (owner, no creadora) SÍ puede editar.
            try await client.execute(
                uri: "/trips/\(viaje.id)/itinerary/\(itemId)", method: .patch,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"title":"Editado por owner"}"#)
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"title\":\"Editado por owner\""))
            }

            // ana (owner) SÍ puede borrar.
            try await client.execute(
                uri: "/trips/\(viaje.id)/itinerary/\(itemId)", method: .delete,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .noContent)
            }
        }
    }

    // 7. Editar en viaje cerrado -> 409, incluso siendo el creador.
    @Test func editarEnViajeCerrado409() async throws {
        let repo = RepositorioEnMemoria()
        let viaje = try await repo.crearViaje(id: "t-cerrado", name: "Roma", baseCurrency: "EUR", creador: MiembroId("ana"), ahora: .now)
        await repo.anadirMiembro(MiembroId("ana"), a: viaje.id)

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
            var itemId = ""
            try await client.execute(
                uri: "/trips/\(viaje.id)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearItemJSON()
            ) { res in itemId = idDe(String(buffer: res.body)) }

            // `Membresia.viajeCerrado` (almacén `cerrados`) es un almacén DISTINTO del
            // `closedAt` de `ViajeRepositorio.cerrar` (mismo patrón que
            // CasosDeUsoItinerarioTests/CasosDeUsoVotacionTests): se cierra vía el
            // helper de test, no vía el endpoint POST /close.
            await repo.cerrarViaje(viaje.id)

            try await client.execute(
                uri: "/trips/\(viaje.id)/itinerary/\(itemId)", method: .patch,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"title":"No debería poder"}"#)
            ) { res in
                #expect(res.status.code == 409)
                #expect(String(buffer: res.body).contains("trip_closed"))
            }
        }
    }

    // 8. Crear en viaje cerrado -> 409.
    @Test func crearEnViajeCerrado409() async throws {
        let repo = RepositorioEnMemoria()
        let viaje = try await repo.crearViaje(id: "t-cerrado-2", name: "Roma", baseCurrency: "EUR", creador: MiembroId("ana"), ahora: .now)
        await repo.anadirMiembro(MiembroId("ana"), a: viaje.id)

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

        // Ver nota de `editarEnViajeCerrado409`: `cerrarViaje` (helper de test) es el
        // almacén que consulta `Membresia.viajeCerrado`, no el POST /close.
        await repo.cerrarViaje(viaje.id)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(viaje.id)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana")], body: crearItemJSON()
            ) { res in
                #expect(res.status.code == 409)
                #expect(String(buffer: res.body).contains("trip_closed"))
            }
        }
    }

    // Extra: sin token, 401 (misma frontera de auth que gastos/settle/trips/polls).
    @Test func sinTokenItinerary401() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/itinerary", method: .get) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    /// GET /trips/:id/itinerary?limit= — el tope llega desde el query, y un `limit`
    /// basura NO se rechaza con 4xx (mismo criterio que ChatRoutes).
    @Test func limitDelQuerySeAplicaYUnValorInvalidoNoEs4xx() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            for titulo in ["Coliseo", "Foro", "Vaticano"] {
                try await client.execute(
                    uri: "/trips/\(trip)/itinerary", method: .post,
                    headers: [.authorization: try await bearer("ana")],
                    body: crearItemJSON(title: titulo)
                ) { res in #expect(res.status == .created) }
            }

            try await client.execute(
                uri: "/trips/\(trip)/itinerary?limit=1", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                #expect(contarOcurrencias(String(buffer: res.body), de: "\"title\":") == 1)
            }
            for basura in ["abc", "0", "-1", ""] {
                try await client.execute(
                    uri: "/trips/\(trip)/itinerary?limit=\(basura)", method: .get,
                    headers: [.authorization: try await bearer("ana")]
                ) { res in
                    #expect(res.status == .ok, "limit='\(basura)' no debe dar 4xx")
                }
            }
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(contarOcurrencias(String(buffer: res.body), de: "\"title\":") == 3)
            }
        }
    }

    /// El PATCH carga la actividad con `detalle`, no buscándola dentro de `listar`:
    /// debe seguir funcionando sobre una actividad que NO cabría en la primera página.
    /// (Con la implementación anterior esto habría devuelto 403.)
    @Test func patchFuncionaSobreUnaActividadFueraDeLaPrimeraPagina() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var ids: [String] = []
            for titulo in ["Coliseo", "Foro", "Vaticano"] {
                try await client.execute(
                    uri: "/trips/\(trip)/itinerary", method: .post,
                    headers: [.authorization: try await bearer("ana")],
                    body: crearItemJSON(title: titulo)
                ) { res in ids.append(idDe(String(buffer: res.body))) }
            }
            // La última por orden (day, orderIndex, id) — desempate por id, todas
            // comparten day y orderIndex.
            let ultima = ids.sorted().last ?? ""

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(ultima)", method: .patch,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"title":"Renombrada"}"#)
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"title\":\"Renombrada\""))
            }
        }
    }
}
