// Tests del endpoint HTTP `POST .../reservation/confirmation` (dy5
// "confirmaciones -> auto-marca el wedge", spec
// docs/superpowers/specs/2026-07-25-dy5-confirmaciones-design.md) contra el adaptador EN MEMORIA. Mismo
// espíritu que ReservaRoutesTests: JWT firmado de verdad, router real, mapeo
// a status codes. El `EstructuradorConfirmacion` wireado en `app()` es el
// FAKE (`EstructuradorConfirmacionFake`) — devuelve `datos` fijos salvo que
// el texto contenga el marcador `"__ILEGIBLE__"`, en cuyo caso lanza (camino
// de error, ver `Confirmacion.swift`).

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

private struct ConfirmacionRespuestaTest: Decodable {
    let tipo: String
    let fechaISO: String?
    let numeroConfirmacion: String?
    let proveedor: String?
}

@Suite("Endpoints HTTP de confirmación de reserva (dy5)")
struct ConfirmacionRoutesTests {
    let trip = "trip-1"
    static let clave = ClaveDePrueba(kid: "test")
    func bearer(_ sub: String) async throws -> String { "Bearer \(try await firmar(Self.clave, sub: sub))" }

    /// Datos fijos que devuelve el fake por defecto (camino feliz).
    static let datosFake = DatosConfirmacion(
        tipo: .vuelo, fechaISO: "2026-08-02", numeroConfirmacion: "ABC123", proveedor: "Iberia")

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
            casosReserva: CasosDeUsoReserva(repo: repo, itinerario: repo, membresia: repo, viajes: repo,
                estructurador: EstructuradorConfirmacionFake(datos: Self.datosFake)),
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

    /// Extrae crudamente el `"id":"..."` del primer match del body (mismo truco que ReservaRoutesTests).
    func idDe(_ body: String) -> String {
        guard let r = body.range(of: #""id":""#) else { return "" }
        let rest = body[r.upperBound...]
        return String(rest.prefix(while: { $0 != "\"" }))
    }

    func crearActividad(_ client: some TestClientProtocol, tripId: String, creador: String) async throws -> String {
        var itemId = ""
        try await client.execute(
            uri: "/trips/\(tripId)/itinerary", method: .post,
            headers: [.authorization: try await bearer(creador), HTTPField.Name("idempotency-key")!: "k-conf-itin", HTTPField.Name("idempotency-first-sent")!: isoReciente()], body: crearItemJSON()
        ) { res in itemId = idDe(String(buffer: res.body)) }
        return itemId
    }

    /// Crea una actividad y define su aspecto reserva `cadaUnoElSuyo` con `ana` e `ivan`
    /// como participantes (helper compartido por los tests de confirmación).
    func crearActividadConReserva(_ client: some TestClientProtocol) async throws -> String {
        let itemId = try await crearActividad(client, tripId: trip, creador: "ana")
        try await client.execute(
            uri: "/trips/\(trip)/itinerary/\(itemId)/reservation", method: .put,
            headers: [.authorization: try await bearer("ana")],
            body: ByteBuffer(string: #"{"kind":"vuelo","mode":"cadaUnoElSuyo","participantes":["ana","ivan"]}"#)
        ) { _ in }
        return itemId
    }

    // 1. POST confirmation con texto válido por un miembro incluido -> 200 con el DTO.
    @Test func confirmarPorMiembroIncluidoOK() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividadConReserva(client)

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation/confirmation", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"confirmationText":"Vuelo IB1234 confirmado, 2026-08-02"}"#)
            ) { res in
                #expect(res.status == .ok)
                let dto = try JSONDecoder().decode(ConfirmacionRespuestaTest.self, from: Data(buffer: res.body))
                #expect(dto.tipo == "vuelo")
                #expect(dto.fechaISO == "2026-08-02")
                #expect(dto.numeroConfirmacion == "ABC123")
                #expect(dto.proveedor == "Iberia")
            }

            // El estado del actor queda marcado `.reservado` en el tablero.
            // (JSONEncoder no garantiza el orden de las claves — ver cabecera de
            // ReservaRoutesTests — así que se comprueban por separado, no como
            // substring concatenado.)
            try await client.execute(
                uri: "/trips/\(trip)/reservations", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                let body = String(buffer: res.body)
                #expect(body.contains(#""memberId":"ana""#))
                #expect(body.contains(#""estado":"reservado""#))
            }
        }
    }

    // 2. POST confirmation por un no-miembro -> 403 (sin fuga).
    @Test func confirmarPorNoMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividadConReserva(client)

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation/confirmation", method: .post,
                headers: [.authorization: try await bearer("sara")],
                body: ByteBuffer(string: #"{"confirmationText":"Vuelo IB1234 confirmado"}"#)
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // 3. POST confirmation con texto ilegible ("__ILEGIBLE__") -> 422 confirmacion_ilegible.
    @Test func confirmarConTextoIlegible422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividadConReserva(client)

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation/confirmation", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"confirmationText":"__ILEGIBLE__"}"#)
            ) { res in
                #expect(res.status.code == 422)
                #expect(String(buffer: res.body).contains("confirmacion_ilegible"))
            }
        }
    }

    // 4. POST confirmation sin `confirmationText` en el body -> 400/422 (decode falla, no crash).
    @Test func confirmarSinConfirmationText400o422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividadConReserva(client)

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation/confirmation", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{}"#)
            ) { res in
                #expect(res.status.code == 400 || res.status.code == 422)
            }
        }
    }

    // Extra: sin token -> 401 (misma frontera de auth que el resto de rutas).
    @Test func sinTokenConfirmation401() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let itemId = try await crearActividadConReserva(client)

            try await client.execute(
                uri: "/trips/\(trip)/itinerary/\(itemId)/reservation/confirmation", method: .post,
                body: ByteBuffer(string: #"{"confirmationText":"Vuelo IB1234 confirmado"}"#)
            ) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
