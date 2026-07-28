// not_member en la API directa de gastos (bead 55x): transversal a los 3 caminos de
// escritura directos — crear/editar/eliminar deben dar 403, igual que los otros 7
// módulos (Settle/Itinerario/Votación/Viaje/Foto/Reserva/Chat). Antes
// `respuestaDirecta` mapeaba TODO `.rechazado` a 422, sin distinguir autorización de
// reglas de negocio (ver GastosDesdeReciboRoutesTests.noMiembro403 para el camino de
// from-receipt, ADR-0025, que reusa el mismo helper).
//
// Mismo harness (app en memoria + JWT real) que RoutesTests, en archivo aparte para
// no crecer esa suite por encima del límite de SwiftLint.

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("not_member en la API directa de gastos")
struct GastosNoMiembroRoutesTests {

    let trip = "trip-1"

    static let clave = ClaveDePrueba(kid: "test")

    func bearer(_ sub: String) async throws -> String {
        "Bearer \(try await firmar(Self.clave, sub: sub))"
    }

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
            casosReserva: CasosDeUsoReserva(
                repo: repo, itinerario: repo, membresia: repo, viajes: repo,
                estructurador: EstructuradorConfirmacionFake(
                    datos: DatosConfirmacion(tipo: .vuelo, fechaISO: nil, numeroConfirmacion: nil, proveedor: nil))),
            casosChat: CasosDeUsoChat(repo: repo, membresia: repo),
            casosFoto: CasosDeUsoFoto(repo: repo, membresia: repo, viajes: repo, storage: FotoStorageStub()),
            casosBrujula: CasosDeUsoBrujula(repo: repo, membresia: repo, settlements: repo, asistente: AsistenteStub()),
            repo: repo,
            pingBD: { true },
            verificador: VerificadorSupabase(
                fuente: FuenteFalsa(jwks(Self.clave)),
                issuer: issDePrueba,
                audiencia: audDePrueba
            )
        )
        return (Application(router: construirRouter(deps)), repo)
    }

    func gastoJSON(id: String, amount: String = "30.00") -> ByteBuffer {
        ByteBuffer(string: #"{"id":"\#(id)","paidBy":"ana","amount":"\#(amount)","currency":"EUR","split":{"kind":"equal","among":["ana","ivan"]}}"#)
    }

    @Test func noMiembroCrear403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [.authorization: try await bearer("sara"), HTTPField.Name("idempotency-key")!: "k1", HTTPField.Name("idempotency-first-sent")!: isoReciente()],
                body: gastoJSON(id: "g1")
            ) { res in
                #expect(res.status == .forbidden)
                #expect(res.headers[HTTPField.Name("x-error-code")!] == "not_member")
            }
        }
    }

    @Test func noMiembroEditar403() async throws {
        let (app, _) = await app()
        // El gasto lo crea 'ana' (miembro); 'sara' (no-miembro) intenta editarlo.
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k1", HTTPField.Name("idempotency-first-sent")!: isoReciente()],
                body: gastoJSON(id: "g1")
            ) { res in #expect(res.status == .created) }

            try await client.execute(
                uri: "/trips/\(trip)/expenses/g1", method: .patch,
                headers: [.authorization: try await bearer("sara"), HTTPField.Name("idempotency-key")!: "k2", HTTPField.Name("idempotency-first-sent")!: isoReciente(),
                          .ifMatch: "cualquier-etag"],
                body: gastoJSON(id: "g1", amount: "40.00")
            ) { res in
                #expect(res.status == .forbidden)
                #expect(res.headers[HTTPField.Name("x-error-code")!] == "not_member")
            }
        }
    }

    @Test func noMiembroEliminar403() async throws {
        let (app, _) = await app()
        // El gasto lo crea 'ana' (miembro); 'sara' (no-miembro) intenta borrarlo.
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k1", HTTPField.Name("idempotency-first-sent")!: isoReciente()],
                body: gastoJSON(id: "g1")
            ) { res in #expect(res.status == .created) }

            try await client.execute(
                uri: "/trips/\(trip)/expenses/g1", method: .delete,
                headers: [.authorization: try await bearer("sara"), HTTPField.Name("idempotency-key")!: "k2", HTTPField.Name("idempotency-first-sent")!: isoReciente(),
                          .ifMatch: "cualquier-etag"]
            ) { res in
                #expect(res.status == .forbidden)
                #expect(res.headers[HTTPField.Name("x-error-code")!] == "not_member")
            }
        }
    }
}
