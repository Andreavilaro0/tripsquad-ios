// Tests de los endpoints HTTP del wedge "quién ya reservó" (spec
// docs/design/wedge-reserva-por-persona-scope.md) contra el adaptador EN
// MEMORIA. El foco es la AUTORIZACIÓN — mismo espíritu que
// ItinerarioRoutesTests, cruzando la frontera HTTP real (JWT firmado de
// verdad, router real, mapeo a status codes).
//
// NOTA sobre el repo en memoria (ver ItinerarioRoutesTests): `Membresia`
// (almacén `miembros`, via `anadirMiembro`) y `ViajeRepositorio.rol`
// (almacén `miembrosDeViaje`, via `crearViaje`/`unirsePorCodigo`) son DOS
// almacenes separados. Los tests que solo necesitan crear/marcar/listar
// usan `anadirMiembro`; los tests de owner-no-creador necesitan además
// `crearViaje` para que `rol` devuelva `.owner` de verdad.

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

// DTOs de LECTURA del body de respuesta (mismo patrón que `RespSugerenciaTest`
// de SettleRoutesTests): `JSONEncoder` NO garantiza el orden de las claves
// dentro de un objeto (depende del runtime, no del orden de declaración de la
// struct), así que comparar el body como substring concatenado de VARIOS
// campos (p.ej. `{"memberId":"ana","estado":"pendiente"}`) es frágil. Decodificar
// es la forma robusta de verificar la asociación miembro->estado.
private struct EstadoMiembroRespuestaTest: Decodable { let memberId: String; let estado: String }
private struct ModoRespuestaTest: Decodable {
    let tipo: String
    let estados: [EstadoMiembroRespuestaTest]?
    let responsable: String?
    let estado: String?
}
private struct ReservaRespuestaTest: Decodable {
    let activityId: String
    let tripId: String
    let kind: String
    let mode: ModoRespuestaTest
}
private struct ReservasListRespuestaTest: Decodable { let items: [ReservaRespuestaTest] }

@Suite("Endpoints HTTP de reserva (wedge quién-ya-reservó)")
struct ReservaRoutesTests {
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

    func crearItemJSON(title: String = "Vuelo a Roma", day: String = "2026-08-02") -> ByteBuffer {
        ByteBuffer(string: #"{"title":"\#(title)","day":"\#(day)"}"#)
    }

    /// Extrae crudamente el `"id":"..."` del primer match del body (mismo truco que ItinerarioRoutesTests).
    func idDe(_ body: String) -> String {
        guard let r = body.range(of: #""id":""#) else { return "" }
        let rest = body[r.upperBound...]
        return String(rest.prefix(while: { $0 != "\"" }))
    }

    /// Crea una actividad de itinerario vía HTTP (helper compartido por los tests de
    /// reserva) y devuelve su id. `creador` es quien manda el POST.
    func crearActividad(_ client: some TestClientProtocol, tripId: String, creador: String) async throws -> String {
        var itemId = ""
        try await client.execute(
            uri: "/trips/\(tripId)/itinerary", method: .post,
            headers: [.authorization: try await bearer(creador)], body: crearItemJSON()
        ) { res in itemId = idDe(String(buffer: res.body)) }
        return itemId
    }

    // 1. PUT reservation por el creador de la actividad (cadaUnoElSuyo) -> 201 con el DTO.
    @Test func definirPorCreadorOK() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividad(client, tripId: trip, creador: "ana")

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"kind":"vuelo","mode":"cadaUnoElSuyo","participantes":["ana","ivan"]}"#)
            ) { res in
                #expect(res.status == .created)
                let dto = try JSONDecoder().decode(ReservaRespuestaTest.self, from: Data(buffer: res.body))
                #expect(dto.activityId == itemId)
                #expect(dto.tripId == trip)
                #expect(dto.kind == "vuelo")
                #expect(dto.mode.tipo == "cadaUnoElSuyo")
                let estados = Dictionary(uniqueKeysWithValues: (dto.mode.estados ?? []).map { ($0.memberId, $0.estado) })
                #expect(estados["ana"] == "pendiente")
                #expect(estados["ivan"] == "pendiente")
            }
        }
    }

    // 2. PUT status propio (cadaUnoElSuyo) -> 200 con el estado actualizado.
    @Test func marcarEstadoPropioOK() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividad(client, tripId: trip, creador: "ana")
            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"kind":"vuelo","mode":"cadaUnoElSuyo","participantes":["ana","ivan"]}"#)
            ) { _ in }

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation/status", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"memberId":"ana","estado":"reservado"}"#)
            ) { res in
                #expect(res.status == .ok)
                let dto = try JSONDecoder().decode(ReservaRespuestaTest.self, from: Data(buffer: res.body))
                let estados = Dictionary(uniqueKeysWithValues: (dto.mode.estados ?? []).map { ($0.memberId, $0.estado) })
                #expect(estados["ana"] == "reservado")
                // El de ivan no se toca.
                #expect(estados["ivan"] == "pendiente")
            }
        }
    }

    // 3. PUT status ajeno por alguien que no es el owner ni el propio miembro -> 403.
    @Test func marcarEstadoAjenoSinOwner403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividad(client, tripId: trip, creador: "ana")
            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"kind":"vuelo","mode":"cadaUnoElSuyo","participantes":["ana","ivan"]}"#)
            ) { _ in }

            // ivan (no owner) intenta marcar el estado de ana -> 403.
            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation/status", method: .put,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"memberId":"ana","estado":"reservado"}"#)
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 4. PUT reservation con `kind` basura -> 422 enum_invalido (no crash).
    @Test func definirConKindBasura422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividad(client, tripId: trip, creador: "ana")

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"kind":"teletransporte","mode":"cadaUnoElSuyo","participantes":["ana"]}"#)
            ) { res in
                #expect(res.status.code == 422)
                #expect(String(buffer: res.body).contains("enum_invalido"))
            }
        }
    }

    // 4b. PUT reservation con `mode` basura -> 422 enum_invalido (mismo criterio que kind).
    @Test func definirConModeBasura422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividad(client, tripId: trip, creador: "ana")

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"kind":"vuelo","mode":"a-medias","participantes":["ana"]}"#)
            ) { res in
                #expect(res.status.code == 422)
                #expect(String(buffer: res.body).contains("enum_invalido"))
            }
        }
    }

    // 4c. PUT reservation con `estado` basura en /status -> 422 enum_invalido.
    @Test func marcarConEstadoBasura422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividad(client, tripId: trip, creador: "ana")
            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"kind":"vuelo","mode":"cadaUnoElSuyo","participantes":["ana"]}"#)
            ) { _ in }

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation/status", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"memberId":"ana","estado":"confirmadisimo"}"#)
            ) { res in
                #expect(res.status.code == 422)
                #expect(String(buffer: res.body).contains("enum_invalido"))
            }
        }
    }

    // 5. GET /reservations por no-miembro -> 403 (sin fuga).
    @Test func tableroPorNoMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/reservations", method: .get,
                headers: [.authorization: try await bearer("sara")]
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 6. GET /reservations devuelve el tablero completo del viaje.
    @Test func tableroDevuelveReservas() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividad(client, tripId: trip, creador: "ana")
            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"kind":"hotel","mode":"unoParaTodos","responsable":"ana"}"#)
            ) { _ in }

            // ivan (solo miembro, ni creador ni responsable) SÍ puede leer el tablero.
            try await client.execute(
                uri: "/trips/\(trip)/reservations", method: .get,
                headers: [.authorization: try await bearer("ivan")]
            ) { res in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                #expect(body.contains("\"activityId\":\"\(itemId)\""))
                #expect(body.contains("\"kind\":\"hotel\""))
                #expect(body.contains("\"tipo\":\"unoParaTodos\""))
                #expect(body.contains("\"responsable\":\"ana\""))
                #expect(body.contains("\"estado\":\"pendiente\""))
            }
        }
    }

    // 7. DELETE reservation por el creador -> 204; ya no aparece en el tablero.
    @Test func quitarPorCreadorOK() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividad(client, tripId: trip, creador: "ana")
            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"kind":"coche","mode":"unoParaTodos","responsable":null}"#)
            ) { _ in }

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .delete,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .noContent)
            }

            try await client.execute(
                uri: "/trips/\(trip)/reservations", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(!String(buffer: res.body).contains(itemId))
            }
        }
    }

    // 8. Definir por alguien que no es ni creador ni owner -> 403.
    @Test func definirPorOtroMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            // ana crea la actividad (es la creadora); ivan es solo miembro.
            let itemId = try await crearActividad(client, tripId: trip, creador: "ana")

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"kind":"vuelo","mode":"unoParaTodos","responsable":null}"#)
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 9. El owner del viaje (no creador de la actividad) SÍ puede marcar el estado ajeno.
    @Test func ownerPuedeMarcarEstadoAjeno() async throws {
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
            // ivan (member, no owner) crea -> es el creador de la actividad.
            let itemId = try await crearActividad(client, tripId: viaje.id, creador: "ivan")

            try await client.execute(
                uri: "/trips/\(viaje.id)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ivan")],
                body: ByteBuffer(string: #"{"kind":"vuelo","mode":"cadaUnoElSuyo","participantes":["ana","ivan"]}"#)
            ) { _ in }

            // ana (owner, no creadora de la actividad, tampoco es el miembro objetivo)
            // SÍ puede marcar el estado de ivan.
            try await client.execute(
                uri: "/trips/\(viaje.id)/itinerary/\(itemId)/reservation/status", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"memberId":"ivan","estado":"reservado"}"#)
            ) { res in
                #expect(res.status == .ok)
                let dto = try JSONDecoder().decode(ReservaRespuestaTest.self, from: Data(buffer: res.body))
                let estados = Dictionary(uniqueKeysWithValues: (dto.mode.estados ?? []).map { ($0.memberId, $0.estado) })
                #expect(estados["ivan"] == "reservado")
            }
        }
    }

    // 10. Definir en viaje cerrado -> 409, incluso siendo el creador.
    @Test func definirEnViajeCerrado409() async throws {
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
            let itemId = try await crearActividad(client, tripId: viaje.id, creador: "ana")

            // Ver nota de ItinerarioRoutesTests.editarEnViajeCerrado409: `cerrarViaje`
            // (helper de test) es el almacén que consulta `Membresia.viajeCerrado`, no
            // el POST /close.
            await repo.cerrarViaje(viaje.id)

            try await client.execute(
                uri: "/trips/\(viaje.id)/itinerary/\(itemId)/reservation", method: .put,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"kind":"vuelo","mode":"unoParaTodos","responsable":null}"#)
            ) { res in
                #expect(res.status.code == 409)
                #expect(String(buffer: res.body).contains("trip_closed"))
            }
        }
    }

    // Extra: sin token, 401 (misma frontera de auth que el resto de rutas).
    @Test func sinTokenReservations401() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/reservations", method: .get) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
