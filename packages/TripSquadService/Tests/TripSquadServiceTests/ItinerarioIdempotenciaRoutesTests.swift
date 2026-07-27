// Test de idempotencia (bead 379) del POST de itinerario, en fichero aparte para no
// engordar el struct de `ItinerarioRoutesTests` (ya cerca del límite de tamaño). Valida
// lo específico de itinerario: la cabecera `etag` (bead 201) SOBREVIVE al replay, además
// de las garantías comunes (400 sin key, no duplica en el reintento).

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Itinerario: idempotencia del POST (bead 379)")
struct ItinerarioIdempotenciaRoutesTests {
    let trip = "trip-1"
    static let clave = ClaveDePrueba(kid: "test")
    func bearer(_ sub: String) async throws -> String { "Bearer \(try await firmar(Self.clave, sub: sub))" }

    func app() async -> any ApplicationProtocol {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(MiembroId("ana"), a: trip)
        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            casosViaje: CasosDeUsoViaje(repo: repo),
            casosVotacion: CasosDeUsoVotacion(repo: repo, membresia: repo, viajes: repo),
            casosItinerario: CasosDeUsoItinerario(repo: repo, membresia: repo, viajes: repo),
            casosReserva: CasosDeUsoReserva(repo: repo, itinerario: repo, membresia: repo, viajes: repo, estructurador: EstructuradorConfirmacionFake(datos: DatosConfirmacion(tipo: .vuelo, fechaISO: nil, numeroConfirmacion: nil, proveedor: nil))),
            casosChat: CasosDeUsoChat(repo: repo, membresia: repo),
            casosFoto: CasosDeUsoFoto(repo: repo, membresia: repo, viajes: repo, storage: FotoStorageStub()),
            casosBrujula: CasosDeUsoBrujula(repo: repo, membresia: repo, settlements: repo, asistente: AsistenteStub()),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        return Application(router: construirRouter(deps))
    }

    func itemJSON(_ title: String = "Coliseo") -> ByteBuffer {
        ByteBuffer(string: #"{"title":"\#(title)","day":"2026-08-02"}"#)
    }

    @Test func postSinKey400_conMismaKeyReplayConEtagYSinDuplicar() async throws {
        let app = await app()
        try await app.test(.router) { client in
            // Sin Idempotency-Key -> 400.
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana")], body: itemJSON()
            ) { res in
                #expect(res.status == .badRequest)
                #expect(String(buffer: res.body).contains("missing_idempotency_key"))
            }

            var etag1 = "", body1 = ""
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k-idem", HTTPField.Name("idempotency-first-sent")!: isoReciente()],
                body: itemJSON()
            ) { res in
                #expect(res.status == .created)
                etag1 = res.headers[HTTPField.Name("etag")!] ?? ""
                body1 = String(buffer: res.body)
            }
            #expect(!etag1.isEmpty)

            // Reintento misma clave: mismo body y MISMA cabecera etag (sobrevive al replay).
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k-idem", HTTPField.Name("idempotency-first-sent")!: isoReciente()],
                body: itemJSON()
            ) { res in
                #expect(res.status == .created)
                #expect(res.headers[HTTPField.Name("etag")!] == etag1)
                #expect(String(buffer: res.body) == body1)
            }

            // La lista tiene UNA sola actividad (el reintento no creó otra).
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                let cuerpo = String(buffer: res.body)
                #expect(cuerpo.components(separatedBy: "\"title\":\"Coliseo\"").count - 1 == 1)
            }
        }
    }

    // Bead 5ln (guía §175-180): `Idempotency-First-Sent` es obligatoria; sin ella → 400.
    // Con una fecha fuera de la ventana de deduplicación (>60 días) → 422 idempotency_key_expired,
    // en vez de ejecutar a ciegas una operación caducada.
    @Test func firstSentObligatoriaYVentanaDe60Dias() async throws {
        let app = await app()
        try await app.test(.router) { client in
            // Con Idempotency-Key pero SIN Idempotency-First-Sent -> 400.
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k-a"],
                body: itemJSON()
            ) { res in
                #expect(res.status == .badRequest)
                #expect(String(buffer: res.body).contains("missing_idempotency_first_sent"))
            }

            // Con un First-Sent de hace 61 días -> 422 (fuera de la ventana de 60 días).
            let hace61Dias = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-61 * 24 * 60 * 60))
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .post,
                headers: [.authorization: try await bearer("ana"),
                          HTTPField.Name("idempotency-key")!: "k-b",
                          HTTPField.Name("idempotency-first-sent")!: hace61Dias],
                body: itemJSON()
            ) { res in
                #expect(res.status.code == 422)
                #expect(String(buffer: res.body).contains("idempotency_key_expired"))
            }
        }
    }
}
