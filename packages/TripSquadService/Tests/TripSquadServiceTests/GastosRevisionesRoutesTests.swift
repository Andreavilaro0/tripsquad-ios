// GET /trips/:tripId/expenses/:id/revisions (bead p4b, ADR-0027). Mismo harness
// (app en memoria + JWT real) que RoutesTests, en archivo aparte para no crecer
// esa suite por encima del límite de SwiftLint (mismo criterio que
// GastosNoMiembroRoutesTests).

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("GET revisiones de un gasto (p4b, ADR-0027)")
struct GastosRevisionesRoutesTests {

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

    private struct RevisionDTOTest: Decodable { let editedBy: String; let field: String }
    private struct RevisionesListDTOTest: Decodable { let revisions: [RevisionDTOTest] }

    /// Camino feliz: cualquier miembro ve el historial (is_member(trip_id),
    /// ADR-0013 §4) — aquí Ana lee la edición que hizo Iván, sin ser la autora,
    /// y ve el autor correcto (`edited_by`).
    @Test func editarConEtagRealDejaRevisionConAutor() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            var etag = ""
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k1", HTTPField.Name("idempotency-first-sent")!: isoReciente()],
                body: gastoJSON(id: "g1")
            ) { res in
                #expect(res.status == .created)
                etag = res.headers[HTTPField.Name("etag")!] ?? ""
            }
            #expect(!etag.isEmpty)

            try await client.execute(
                uri: "/trips/\(trip)/expenses/g1", method: .patch,
                headers: [.authorization: try await bearer("ivan"), HTTPField.Name("idempotency-key")!: "k2", HTTPField.Name("idempotency-first-sent")!: isoReciente(),
                          HTTPField.Name("if-match")!: etag],
                body: gastoJSON(id: "g1", amount: "40.00")
            ) { res in #expect(res.status == .ok) }

            try await client.execute(
                uri: "/trips/\(trip)/expenses/g1/revisions", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RevisionesListDTOTest.self, from: res.body)
                #expect(body.revisions.count == 1)
                #expect(body.revisions.first?.editedBy == "ivan")
            }
        }
    }

    /// No-miembro: 403 sin fuga (mismo criterio que crear/editar/eliminar,
    /// GastosNoMiembroRoutesTests).
    @Test func noMiembroNoLeeElHistorial403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k1", HTTPField.Name("idempotency-first-sent")!: isoReciente()],
                body: gastoJSON(id: "g1")
            ) { res in #expect(res.status == .created) }

            try await client.execute(
                uri: "/trips/\(trip)/expenses/g1/revisions", method: .get,
                headers: [.authorization: try await bearer("sara")]
            ) { res in
                #expect(res.status == .forbidden)
                #expect(res.headers[HTTPField.Name("x-error-code")!] == "not_member")
            }
        }
    }

    /// `expenseId` inexistente: el MISMO 403 sin fuga (no revela si el gasto
    /// existe en otro viaje).
    @Test func gastoInexistente403SinFuga() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses/no-existe/revisions", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .forbidden)
                #expect(res.headers[HTTPField.Name("x-error-code")!] == "not_member")
            }
        }
    }
}
