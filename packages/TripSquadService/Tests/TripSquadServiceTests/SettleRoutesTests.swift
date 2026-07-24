import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

// El flujo de confirmación (crear-lote/confirm/reject/cancel/list, ADR-0017) vive
// aquí junto al GET suggestion (ADR-0016 a). La idempotencia/dedupe de la escritura y
// la máquina de estados en sí siguen cubiertas a nivel de dominio en
// CasosDeUsoSettleTests (paquete TripSquadExpenses); aquí se prueba el CABLEADO HTTP:
// el mapeo de ResultadoTransicion/ResultadoSettle a status codes y el reloj inyectado.
@Suite("Endpoints :settle — flujo de confirmación (ADR-0017)")
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
            casosViaje: CasosDeUsoViaje(repo: repo),
            casosVotacion: CasosDeUsoVotacion(repo: repo, membresia: repo, viajes: repo),
            casosItinerario: CasosDeUsoItinerario(repo: repo, membresia: repo, viajes: repo),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        return (Application(router: construirRouter(deps)), repo)
    }

    /// Crea UN pago vía HTTP y devuelve el id que asignó el servidor (lo necesitan
    /// los tests de confirm/reject/cancel/list).
    func crearId(_ app: any ApplicationProtocol, actor: String, from: String, to: String,
                 settlementId: String, transferIndex: Int = 0, amountMinor: Int64 = 1000) async throws -> String {
        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"settlements":[{"settlementId":"\#(settlementId)","from":"\#(from)","to":"\#(to)","transferIndex":\#(transferIndex),"amountMinor":\#(amountMinor)}]}"#)
            return try await client.execute(
                uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer(actor)], body: body
            ) { res in
                let decoded = try JSONDecoder().decode(RespCrearLoteTest.self, from: Data(buffer: res.body))
                return decoded.created.first?.id ?? ""
            }
        }
    }

    /// Crea un gasto vía HTTP para sembrar deuda (40.00 EUR pagados por ana, split
    /// equal ana/ivan → ivan debe 2000 a ana). Es el mismo camino que usan los tests de
    /// `RoutesTests`; más simple que sembrar el repo en memoria a mano.
    func sembrarDeuda(_ app: any ApplicationProtocol) async throws {
        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"id":"g1","paidBy":"ana","amount":"40.00","currency":"EUR","split":{"kind":"equal","among":["ana","ivan"]}}"#)
            try await client.execute(
                uri: "/trips/\(trip)/expenses", method: .post,
                headers: [.authorization: try await bearer("ana"), HTTPField.Name("idempotency-key")!: "k-deuda"],
                body: body
            ) { res in
                #expect(res.status == .created)
            }
        }
    }

    // MARK: - Task 5: confirmados descuentan + aviso de pendientes

    @Test func confirmadoReduceLaSugerencia() async throws {
        let (app, _) = await app()
        try await sembrarDeuda(app)
        // ivan debe 2000 a ana; ivan afirma el pago y ana (contraparte) lo confirma.
        let id = try await crearId(app, actor: "ivan", from: "ivan", to: "ana", settlementId: "s-confirma", amountMinor: 2000)
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements/\(id)/confirm", method: .post,
                headers: [.authorization: try await bearer("ana")]) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/trips/\(trip)/settlement/suggestion", method: .get,
                headers: [.authorization: try await bearer("ana")]) { res in
                #expect(res.status == .ok)
                let decoded = try JSONDecoder().decode(RespSugerenciaTest.self, from: Data(buffer: res.body))
                #expect(decoded.transfers.isEmpty)
            }
        }
    }

    @Test func avisoDePendienteEnLaSugerencia() async throws {
        let (app, _) = await app()
        try await sembrarDeuda(app)
        // ivan afirma el pago pero NADIE lo confirma todavía: sigue pending.
        _ = try await crearId(app, actor: "ivan", from: "ivan", to: "ana", settlementId: "s-pend", amountMinor: 2000)
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlement/suggestion", method: .get,
                headers: [.authorization: try await bearer("ana")]) { res in
                #expect(res.status == .ok)
                let decoded = try JSONDecoder().decode(RespSugerenciaTest.self, from: Data(buffer: res.body))
                let t = try #require(decoded.transfers.first { $0.from == "ivan" && $0.to == "ana" })
                #expect(t.pending == true)
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

    // Finding D (revisión multi-modelo): la autorización va ANTES de leer gastos. Este repo
    // dice "no miembro" y LANZA en gastos(): si el orden fuese al revés, gastos() explotaría
    // y el cliente vería 5xx. Debe ver 403.
    @Test func noMiembroNoLlegaALeerGastos403() async throws {
        let repo = RepoNoMiembroQueLanzaEnGastos()
        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            // RepoNoMiembroQueLanzaEnGastos no conforma ViajeRepositorio/VotacionRepositorio/
            // ItinerarioRepositorio y este test no ejercita /trips ni /polls ni /itinerary:
            // un repo en memoria aparte basta.
            casosViaje: CasosDeUsoViaje(repo: RepositorioEnMemoria()),
            casosVotacion: CasosDeUsoVotacion(repo: RepositorioEnMemoria(), membresia: RepositorioEnMemoria(), viajes: RepositorioEnMemoria()),
            casosItinerario: CasosDeUsoItinerario(repo: RepositorioEnMemoria(), membresia: RepositorioEnMemoria(), viajes: RepositorioEnMemoria()),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        let app = Application(router: construirRouter(deps))
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlement/suggestion", method: .get,
                headers: [.authorization: try await bearer("sara")]) { res in
                #expect(res.status == .forbidden)   // 403, no 5xx: la authz cortó antes de gastos()
            }
        }
    }

    // MARK: - POST crear-lote

    @Test func crearLote201ConItemPending() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"settlements":[{"settlementId":"s1","from":"ana","to":"ivan","transferIndex":0,"amountMinor":500}]}"#)
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ana")], body: body) { res in
                #expect(res.status == .created)
                #expect(String(buffer: res.body).contains("\"status\":\"pending\""))
            }
        }
    }

    @Test func crearLoteReintentoMismaClaveEsDuplicate() async throws {
        let (app, _) = await app()
        let body = ByteBuffer(string: #"{"settlements":[{"settlementId":"s1","from":"ana","to":"ivan","transferIndex":0,"amountMinor":500}]}"#)
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ana")], body: body) { _ in }
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ana")], body: body) { res in
                #expect(res.status == .ok)   // nada nuevo creado -> 200
                #expect(String(buffer: res.body).contains("\"status\":\"duplicate\""))
            }
        }
    }

    @Test func crearLoteImporteCeroDaInvalidAmount() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"settlements":[{"settlementId":"s0","from":"ana","to":"ivan","transferIndex":0,"amountMinor":0}]}"#)
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ana")], body: body) { res in
                #expect(res.status == .ok)   // ningún item creado -> 200
                #expect(String(buffer: res.body).contains("\"code\":\"invalid_amount\""))
            }
        }
    }

    @Test func crearLoteActorNoParteDaActorNotParty() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            // ana llama, pero el pago es entre ivan y ella misma no figura como parte.
            let body = ByteBuffer(string: #"{"settlements":[{"settlementId":"s2","from":"ivan","to":"ivan","transferIndex":0,"amountMinor":500}]}"#)
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ana")], body: body) { res in
                #expect(String(buffer: res.body).contains("\"code\":\"actor_not_party\""))
            }
        }
    }

    @Test func crearLoteNoMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"settlements":[{"settlementId":"s3","from":"ana","to":"ivan","transferIndex":0,"amountMinor":500}]}"#)
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("sara")], body: body) { res in
                #expect(res.status == .forbidden)
                #expect(String(buffer: res.body).contains("not_member"))
            }
        }
    }

    // MARK: - POST confirm/reject/cancel

    @Test func confirmarPorContraparte200LuegoOtraVez409() async throws {
        let (app, _) = await app()
        let id = try await crearId(app, actor: "ana", from: "ana", to: "ivan", settlementId: "s4")
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements/\(id)/confirm", method: .post,
                headers: [.authorization: try await bearer("ivan")]) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/trips/\(trip)/settlements/\(id)/confirm", method: .post,
                headers: [.authorization: try await bearer("ivan")]) { res in
                #expect(res.status.code == 409)
                #expect(String(buffer: res.body).contains("invalid_state"))
            }
        }
    }

    @Test func confirmarPorElCreador403() async throws {
        let (app, _) = await app()
        let id = try await crearId(app, actor: "ana", from: "ana", to: "ivan", settlementId: "s5")
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements/\(id)/confirm", method: .post,
                headers: [.authorization: try await bearer("ana")]) { res in
                #expect(res.status == .forbidden)
                #expect(String(buffer: res.body).contains("not_authorized"))
            }
        }
    }

    @Test func cancelarPorElCreador200() async throws {
        let (app, _) = await app()
        let id = try await crearId(app, actor: "ana", from: "ana", to: "ivan", settlementId: "s6")
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements/\(id)/cancel", method: .post,
                headers: [.authorization: try await bearer("ana")]) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func rechazarConReason200() async throws {
        let (app, _) = await app()
        let id = try await crearId(app, actor: "ana", from: "ana", to: "ivan", settlementId: "s7")
        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"reason":"no me llega el gasto"}"#)
            try await client.execute(uri: "/trips/\(trip)/settlements/\(id)/reject", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: body) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func caducidadConfirmarTrasTTLDa409Expired() async throws {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(MiembroId("ana"), a: trip)
        await repo.anadirMiembro(MiembroId("ivan"), a: trip)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        func deps(ahora: @escaping @Sendable () -> Date) -> Dependencias {
            Dependencias(
                casos: CasosDeUsoGastos(repo: repo, membresia: repo),
                casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
                casosViaje: CasosDeUsoViaje(repo: repo),
                casosVotacion: CasosDeUsoVotacion(repo: repo, membresia: repo, viajes: repo),
                casosItinerario: CasosDeUsoItinerario(repo: repo, membresia: repo, viajes: repo),
                repo: repo, pingBD: { true },
                verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba),
                ahora: ahora)
        }

        let appCrear = Application(router: construirRouter(deps(ahora: { t0 })))
        let id = try await crearId(appCrear, actor: "ana", from: "ana", to: "ivan", settlementId: "s-exp")

        let appConfirmar = Application(router: construirRouter(deps(ahora: { t0.addingTimeInterval(31 * 24 * 3600) })))
        try await appConfirmar.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements/\(id)/confirm", method: .post,
                headers: [.authorization: try await bearer("ivan")]) { res in
                #expect(res.status.code == 409)
                #expect(String(buffer: res.body).contains("expired"))
            }
        }
    }

    // MARK: - GET lista de pendientes

    @Test func listaPendientesGET200ContieneElIdCreado() async throws {
        let (app, _) = await app()
        let id = try await crearId(app, actor: "ana", from: "ana", to: "ivan", settlementId: "s8")
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .get,
                headers: [.authorization: try await bearer("ana")]) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains(id))
            }
        }
    }
}

/// DTO mínimo para decodificar la respuesta de POST crear-lote en los tests (los DTOs
/// reales de `SettleRoutes.swift` son `private` al módulo, no visibles desde fuera).
private struct ItemCreadoTest: Decodable { let id: String? }
private struct RespCrearLoteTest: Decodable { let created: [ItemCreadoTest] }

/// DTO mínimo para decodificar el GET suggestion en los tests (Task 5: campo `pending`).
private struct TransferenciaTest: Decodable { let from: String; let to: String; let amountMinor: Int64; let pending: Bool }
private struct RespSugerenciaTest: Decodable { let transfers: [TransferenciaTest] }

/// Repo de prueba para el finding D: NO miembro, y `gastos()` LANZA. Sirve para verificar
/// que la ruta autoriza antes de tocar gastos. El resto de métodos no se ejercitan aquí.
private struct RepoNoMiembroQueLanzaEnGastos: GastoRepositorio, Membresia, SettlementRepositorio {
    struct Boom: Error {}
    func esMiembro(_ miembro: MiembroId, de tripId: String) async throws -> Bool { false }
    func viajeCerrado(_ tripId: String) async throws -> Bool { false }
    func gastos(de tripId: String) async throws -> [GastoConEtag] { throw Boom() }
    func respuestaPrevia(actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura? { throw Boom() }
    func guardar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura { throw Boom() }
    func gasto(id: String, en tripId: String) async throws -> GastoConEtag? { throw Boom() }
    func actualizar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura { throw Boom() }
    func eliminar(id: String, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura { throw Boom() }
    func crear(_ settlement: Settlement) async throws -> ResultadoSettle { throw Boom() }
    func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement,
                      por actor: MiembroId, ahora: Date, rejectReason: String?) async throws -> ResultadoTransicion { throw Boom() }
    func confirmados(de tripId: String) async throws -> [Settlement] { throw Boom() }
    func pendientes(de tripId: String) async throws -> [(String, Settlement)] { throw Boom() }
    func settlement(id: String, en tripId: String) async throws -> Settlement? { throw Boom() }
}
