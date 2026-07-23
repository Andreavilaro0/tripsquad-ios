import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Endpoints :settle (ADR-0016)")
struct SettleRoutesTests {
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
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        return (Application(router: construirRouter(deps)), repo)
    }

    func pago(id: String, amount: Int64 = 2000) -> ByteBuffer {
        ByteBuffer(string: #"{"settlementId":"\#(id)","from":"ivan","to":"ana","transferIndex":0,"amountMinor":\#(amount)}"#)
    }

    @Test func registrarPago201() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: pago(id: "s1")) { res in
                #expect(res.status == .created)
                #expect(String(buffer: res.body).contains("registered"))
            }
        }
    }

    @Test func reintentoMismoIdEs200Duplicate() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            _ = try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: pago(id: "s1")) { _ in }
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: pago(id: "s1")) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("duplicate"))
            }
        }
    }

    @Test func importeCeroEs422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: pago(id: "s1", amount: 0)) { res in
                #expect(res.status.code == 422)
            }
        }
    }

    @Test func sugerenciaGET200() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlement/suggestion", method: .get,
                headers: [.authorization: try await bearer("ana")]) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("transfers"))
            }
        }
    }

    @Test func sugerenciaNoMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlement/suggestion", method: .get,
                headers: [.authorization: try await bearer("sara")]) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // Gate G4 (bead 8hn): N POST concurrentes con el MISMO settlementId → exactamente una
    // registra (201); el resto son 200 duplicate. Nunca dos registros. El actor `RepositorioEnMemoria`
    // serializa las 8 tareas: solo una ve el Set vacío. El adaptador Postgres replica el invariante
    // con ON CONFLICT DO NOTHING (bead futuro de integración Postgres).
    @Test("G4 (8hn): dos POST concurrentes con el mismo settlementId = una registrada")
    func g4_concurrenciaMismoSettlementId() async throws {
        let (app, repo) = await app()
        try await app.test(.router) { client in
            await withTaskGroup(of: Int.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        (try? await client.execute(uri: "/trips/\(self.trip)/settlements", method: .post,
                            headers: [.authorization: try await self.bearer("ivan")], body: self.pago(id: "s-concurrente")) { res in
                            Int(res.status.code)
                        }) ?? 0
                    }
                }
                var registrados201 = 0
                for await code in group where code == 201 { registrados201 += 1 }
                #expect(registrados201 == 1, "solo una petición debe registrar; el resto son idempotentes")
            }
        }
        #expect(await repo.contarSettlements(settlementId: "s-concurrente") == 1)
    }
}
