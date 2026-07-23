// Tests de los endpoints HTTP contra el adaptador EN MEMORIA (sin Postgres). Prueban
// el cableado, la conversión de dinero en la frontera, y la regla del camino de
// /sync/upload (nunca 4xx).

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Endpoints HTTP")
struct RoutesTests {

    let trip = "trip-1"

    /// Clave ES256 de test: los tokens se firman de verdad y el servicio los verifica
    /// de verdad. No hay verificador falso: la auth se ejerce en cada test de ruta.
    static let clave = ClaveDePrueba(kid: "test")

    /// `Authorization` con un token válido cuyo `sub` es el miembro dado.
    func bearer(_ sub: String) async throws -> String {
        "Bearer \(try await firmar(Self.clave, sub: sub))"
    }

    func app(bdOk: Bool = true) async -> (any ApplicationProtocol, RepositorioEnMemoria) {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(MiembroId("ana"), a: trip)
        await repo.anadirMiembro(MiembroId("ivan"), a: trip)
        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
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

    func gastoJSON(id: String, amount: String = "30.00") -> ByteBuffer {
        ByteBuffer(string: #"{"id":"\#(id)","paidBy":"ana","amount":"\#(amount)","currency":"EUR","split":{"kind":"equal","among":["ana","ivan"]}}"#)
    }

    /// /live es liveness: SIEMPRE 200 (el health check de Render), aunque la BD caiga.
    @Test func liveSiempre200() async throws {
        let (app, _) = await app(bdOk: false)   // BD caída y aun así...
        try await app.test(.router) { client in
            try await client.execute(uri: "/live", method: .get) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func healthOk() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func healthDegradedSiBDCae() async throws {
        let (app, _) = await app(bdOk: false)
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { res in
                #expect(res.status == .serviceUnavailable)
            }
        }
    }

    @Test func crearGasto201() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k1"],
                body: gastoJSON(id: "g1")
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
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: gastoJSON(id: "g1")
            ) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test func sinActor401() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [HTTPField.Name("idempotency-key")!: "k1"],
                body: gastoJSON(id: "g1")
            ) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    /// El dinero se convierte en la frontera: "30.00" EUR -> 3000 céntimos.
    @Test func dineroDecimalAConCentimos() async throws {
        let (app, repo) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k1"],
                body: gastoJSON(id: "g1", amount: "30.00")
            ) { res in #expect(res.status == .created) }
        }
        let leidos = await repo.gastos(de: trip)
        #expect(leidos.first?.gasto.importeMinor == 3000)
    }

    /// ⭐ /sync/upload NUNCA devuelve 4xx: un op rechazado (no-miembro) sale como
    /// outcome "rejected" dentro de un 200 (regla del camino, guía §0).
    @Test func syncUploadNuncaDa4xx() async throws {
        let (app, _) = await app()
        // 'sara' NO es miembro -> el op debe salir rejected, pero el status es 200.
        let batch = #"{"deviceId":"dev-A","ops":[{"crudId":"5","op":"PUT","table":"expenses","rowId":"g1","tripId":"\#(trip)","idempotencyKey":"dev-A|5|expenses|g1","data":{"id":"g1","paidBy":"sara","amount":"10.00","currency":"EUR","split":{"kind":"equal","among":["sara"]}}}]}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/sync/upload", method: .post,
                headers: [.authorization: try await bearer("sara")],
                body: ByteBuffer(string: batch)
            ) { res in
                #expect(res.status == .ok, "sync/upload nunca debe dar 4xx")
                let body = String(buffer: res.body)
                #expect(body.contains("\"outcome\":\"rejected\""), "el no-miembro debe salir rejected, no 4xx")
                #expect(body.contains("\"crudId\":\"5\""), "correlación por crudId")
            }
        }
    }

    /// /sync/upload procesa un op válido y devuelve accepted.
    @Test func syncUploadAceptaOpValido() async throws {
        let (app, repo) = await app()
        let batch = #"{"deviceId":"dev-A","ops":[{"crudId":"5","op":"PUT","table":"expenses","rowId":"g1","tripId":"\#(trip)","idempotencyKey":"dev-A|5|expenses|g1","data":{"id":"g1","paidBy":"ana","amount":"30.00","currency":"EUR","split":{"kind":"equal","among":["ana","ivan"]}}}]}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/sync/upload", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: batch)
            ) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"outcome\":\"accepted\""))
            }
        }
        #expect(await repo.gastos(de: trip).count == 1)
    }

    // MARK: - La frontera de autenticación (ADR-0014 §1)

    @Test("Sin token, la API directa responde 401 y NO toca el dominio")
    func apiDirectaSinToken401() async throws {
        let (app, repo) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [HTTPField.Name("idempotency-key")!: "k1"],
                body: gastoJSON(id: "g1")
            ) { res in
                #expect(res.status == .unauthorized)
            }
        }
        #expect(await repo.gastos(de: trip).isEmpty)
    }

    @Test("Sin token, la cola responde 401 (el connector re-autentica, contrato §0)")
    func colaSinToken401() async throws {
        let (app, _) = await app()
        let batch = #"{"deviceId":"dev-A","ops":[]}"#
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/sync/upload", method: .post, body: ByteBuffer(string: batch)
            ) { res in
                #expect(res.status == .unauthorized)
                #expect(String(buffer: res.body).contains("reauth"))
            }
        }
    }

    @Test("Un token de otro proyecto Supabase no entra")
    func tokenDeOtroProyecto401() async throws {
        let (app, _) = await app()
        let intruso = try await firmar(ClaveDePrueba(kid: "test"), sub: "ana")  // otra clave, mismo kid
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [.authorization: "Bearer \(intruso)",
                          HTTPField.Name("idempotency-key")!: "k1"],
                body: gastoJSON(id: "g1")
            ) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("/live y /health siguen siendo públicos (los sondea Render, sin token)")
    func saludSinToken() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/live", method: .get) { #expect($0.status == .ok) }
            try await client.execute(uri: "/health", method: .get) { #expect($0.status == .ok) }
        }
    }

    @Test("Si la JWKS no se puede descargar, la cola recibe 5xx (no 401: no es culpa del cliente)")
    func jwksCaidaEnLaCola() async throws {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(MiembroId("ana"), a: trip)
        let fuente = FuenteFalsa(jwks(Self.clave))
        await fuente.romper()
        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
            repo: repo,
            pingBD: { true },
            verificador: VerificadorSupabase(fuente: fuente, issuer: issDePrueba, audiencia: audDePrueba)
        )
        let app = Application(router: construirRouter(deps))

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/sync/upload", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: #"{"deviceId":"dev-A","ops":[]}"#)
            ) { res in
                #expect(res.status.code >= 500)
                #expect(String(buffer: res.body).contains("transient"))
            }
        }
    }
}
