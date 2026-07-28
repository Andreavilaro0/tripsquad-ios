// Endpoint POST /trips/:tripId/expenses/from-receipt — crear gasto desde un
// recibo itemizado. Mismo harness (app en memoria + JWT real) que GastosRoutes.

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Endpoints HTTP de gastos desde recibo")
struct GastosDesdeReciboRoutesTests {

    let trip = "trip-1"

    static let clave = ClaveDePrueba(kid: "test")

    func bearer(_ sub: String) async throws -> String {
        "Bearer \(try await firmar(Self.clave, sub: sub))"
    }

    func app(bdOk: Bool = true) async -> (any ApplicationProtocol, RepositorioEnMemoria) {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(MiembroId("ana"), a: trip)
        await repo.anadirMiembro(MiembroId("ivan"), a: trip)
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
            repo: repo,
            pingBD: { bdOk },
            verificador: VerificadorSupabase(
                fuente: FuenteFalsa(jwks(Self.clave)),
                issuer: issDePrueba,
                audiencia: audDePrueba
            )
        )
        return (Application(router: construirRouter(deps)), repo)
    }

    func reciboJSON(gastoId: String, pagadoPor: String = "ana",
                    items: String = #"[{"importeMinor":750,"sharers":["ana"]},{"importeMinor":250,"sharers":["ivan"]}]"#,
                    impuestosMinor: Int64 = 100, propinaMinor: Int64 = 0) -> ByteBuffer {
        ByteBuffer(string: #"{"gastoId":"\#(gastoId)","pagadoPor":"\#(pagadoPor)","items":\#(items),"impuestosMinor":\#(impuestosMinor),"propinaMinor":\#(propinaMinor)}"#)
    }

    @Test func creaDesdeRecibo201() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses/from-receipt", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k1", HTTPField.Name("idempotency-first-sent")!: isoReciente()],
                body: reciboJSON(gastoId: "g1")
            ) { res in
                #expect(res.status == .created)
                #expect(res.headers[HTTPField.Name("etag")!] != nil)
            }
        }
    }

    @Test func sinIdempotencyKey400() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses/from-receipt", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: reciboJSON(gastoId: "g1")
            ) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test func reciboInvalido422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses/from-receipt", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k1", HTTPField.Name("idempotency-first-sent")!: isoReciente()],
                body: reciboJSON(gastoId: "g1", items: #"[{"importeMinor":100,"sharers":[]}]"#)
            ) { res in
                #expect(res.status == HTTPResponse.Status(code: 422))
                #expect(res.headers[HTTPField.Name("x-error-code")!] == "invalid_receipt")
            }
        }
    }

    // (bead 55x) not_member es transversal a los 7 módulos: 403, no 422 — from-receipt
    // reusa `respuestaDirecta`, así que hereda el mismo mapeo que crear/editar/eliminar.
    @Test func noMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses/from-receipt", method: .post,
                headers: [.authorization: try await bearer("sara"), HTTPField.Name("idempotency-key")!: "k1", HTTPField.Name("idempotency-first-sent")!: isoReciente()],
                body: reciboJSON(gastoId: "g1", pagadoPor: "sara",
                                 items: #"[{"importeMinor":100,"sharers":["sara"]}]"#)
            ) { res in
                #expect(res.status == .forbidden)
                #expect(res.headers[HTTPField.Name("x-error-code")!] == "not_member")
            }
        }
    }
}
