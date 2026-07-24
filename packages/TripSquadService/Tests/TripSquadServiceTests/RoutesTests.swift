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
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            casosViaje: CasosDeUsoViaje(repo: repo),
            casosVotacion: CasosDeUsoVotacion(repo: repo, membresia: repo, viajes: repo),
            casosItinerario: CasosDeUsoItinerario(repo: repo, membresia: repo, viajes: repo),
            casosChat: CasosDeUsoChat(repo: repo, membresia: repo),
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
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            casosViaje: CasosDeUsoViaje(repo: repo),
            casosVotacion: CasosDeUsoVotacion(repo: repo, membresia: repo, viajes: repo),
            casosItinerario: CasosDeUsoItinerario(repo: repo, membresia: repo, viajes: repo),
            casosChat: CasosDeUsoChat(repo: repo, membresia: repo),
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

    // MARK: - G1 (bead 9hz): el camino de la cola NUNCA devuelve 4xx salvo 409
    //
    // ADR-0012 §4: un 4xx congela la cola de PowerSync para siempre. Por eso el
    // conflicto viaja en 200 (write_conflicts), el rechazo permanente en 200
    // (rejected), y lo transitorio (in_flight, BD caída, body ilegible) en 5xx.
    // Este test enumera TODAS las ramas de error y falla si alguna es 4xx != 409.

    /// Invariante del contrato: prohibido cualquier 4xx salvo 409.
    func no4xxSalvo409(_ code: Int, _ etiqueta: String) {
        let prohibido = (400..<500).contains(code) && code != 409
        #expect(!prohibido, "\(etiqueta): status \(code) — un 4xx≠409 congela la cola (ADR-0012 §4)")
    }

    func gastoStr(id: String, amount: String = "30.00") -> String {
        #"{"id":"\#(id)","paidBy":"ana","amount":"\#(amount)","currency":"EUR","split":{"kind":"equal","among":["ana","ivan"]}}"#
    }
    func batchG1(_ op: String) -> ByteBuffer {
        ByteBuffer(string: #"{"deviceId":"dev-A","ops":[\#(op)]}"#)
    }
    func appCon(_ repo: some GastoRepositorio & Membresia & SettlementRepositorio) -> any ApplicationProtocol {
        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            // Los dobles G1 (RepoQueLanza/RepoInFlight) no conforman ViajeRepositorio/
            // VotacionRepositorio/ItinerarioRepositorio y estos tests no ejercitan
            // /trips ni /polls ni /itinerary: un repo en memoria aparte basta.
            casosViaje: CasosDeUsoViaje(repo: RepositorioEnMemoria()),
            casosVotacion: CasosDeUsoVotacion(repo: RepositorioEnMemoria(), membresia: RepositorioEnMemoria(), viajes: RepositorioEnMemoria()),
            casosItinerario: CasosDeUsoItinerario(repo: RepositorioEnMemoria(), membresia: RepositorioEnMemoria(), viajes: RepositorioEnMemoria()),
            casosChat: CasosDeUsoChat(repo: RepositorioEnMemoria(), membresia: RepositorioEnMemoria()),
            repo: repo,
            pingBD: { true },
            verificador: VerificadorSupabase(
                fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba)
        )
        return Application(router: construirRouter(deps))
    }

    @Test("G1: toda rama de rechazo/conflicto viaja en 200, nunca 4xx")
    func g1_rechazosYConflictoVanEn200() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            // baseline: crear g1 para poder provocar un conflicto de ETag después.
            _ = try await client.execute(
                uri: "/sync/upload", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: batchG1(#"{"crudId":"1","op":"PUT","table":"expenses","rowId":"g1","tripId":"\#(trip)","idempotencyKey":"ana|1","data":\#(gastoStr(id: "g1"))}"#)
            ) { _ in }

            let casos: [(String, String)] = [
                ("PUT sin data",       #"{"crudId":"2","op":"PUT","table":"expenses","rowId":"g2","tripId":"\#(trip)","idempotencyKey":"ana|2"}"#),
                ("PUT data inválida",  #"{"crudId":"3","op":"PUT","table":"expenses","rowId":"g3","tripId":"\#(trip)","idempotencyKey":"ana|3","data":\#(gastoStr(id: "g3", amount: "no-es-numero"))}"#),
                ("PATCH sin ifMatch",  #"{"crudId":"4","op":"PATCH","table":"expenses","rowId":"g1","tripId":"\#(trip)","idempotencyKey":"ana|4","data":\#(gastoStr(id: "g1"))}"#),
                ("DELETE sin ifMatch", #"{"crudId":"5","op":"DELETE","table":"expenses","rowId":"g1","tripId":"\#(trip)","idempotencyKey":"ana|5"}"#),
                ("op desconocida",     #"{"crudId":"6","op":"FOO","table":"expenses","rowId":"g1","tripId":"\#(trip)","idempotencyKey":"ana|6"}"#),
                ("conflicto ETag",     #"{"crudId":"7","op":"PATCH","table":"expenses","rowId":"g1","tripId":"\#(trip)","idempotencyKey":"ana|7","ifMatch":"etag-viejo","data":\#(gastoStr(id: "g1", amount: "40.00"))}"#),
            ]
            for (etiqueta, op) in casos {
                try await client.execute(
                    uri: "/sync/upload", method: .post,
                    headers: [.authorization: try await bearer("ana")],
                    body: batchG1(op)
                ) { res in
                    no4xxSalvo409(Int(res.status.code), etiqueta)
                    #expect(res.status == .ok, "\(etiqueta): debe ser 200 con desenlace por-op")
                }
            }
        }
    }

    @Test("G1: un no-miembro se rechaza dentro de un 200, no con 401/403")
    func g1_noMiembroEn200() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/sync/upload", method: .post,
                headers: [.authorization: try await bearer("sara")],   // sara NO es miembro
                body: batchG1(#"{"crudId":"1","op":"PUT","table":"expenses","rowId":"g1","tripId":"\#(trip)","idempotencyKey":"sara|1","data":\#(gastoStr(id: "g1"))}"#)
            ) { res in
                no4xxSalvo409(Int(res.status.code), "no-miembro")
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("rejected"))
            }
        }
    }

    @Test("G1: un body ilegible NO es 4xx (un 400 congelaría la cola)")
    func g1_bodyMalformadoNoEs4xx() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/sync/upload", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: ByteBuffer(string: "esto no es json { {")
            ) { res in
                no4xxSalvo409(Int(res.status.code), "body ilegible")
                #expect(res.status.code >= 500)
            }
        }
    }

    @Test("G1: in_flight es 503 (transitorio), nunca 409")
    func g1_inFlightEs503() async throws {
        let app = appCon(RepoInFlight())
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/sync/upload", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: batchG1(#"{"crudId":"1","op":"PUT","table":"expenses","rowId":"g1","tripId":"\#(trip)","idempotencyKey":"ana|1","data":\#(gastoStr(id: "g1"))}"#)
            ) { res in
                no4xxSalvo409(Int(res.status.code), "in_flight")
                #expect(res.status.code >= 500)
            }
        }
    }

    @Test("G1: BD caída es 5xx (transitorio), nunca 4xx")
    func g1_bdCaidaEs5xx() async throws {
        let app = appCon(RepoQueLanza())
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/sync/upload", method: .post,
                headers: [.authorization: try await bearer("ana")],
                body: batchG1(#"{"crudId":"1","op":"PUT","table":"expenses","rowId":"g1","tripId":"\#(trip)","idempotencyKey":"ana|1","data":\#(gastoStr(id: "g1"))}"#)
            ) { res in
                no4xxSalvo409(Int(res.status.code), "BD caída")
                #expect(res.status.code >= 500)
            }
        }
    }
}

// MARK: - Dobles para G1 (ramas que el repo en memoria no produce por sí solo)

/// Simula la BD caída: todo lanza. El endpoint debe responder 5xx (transitorio),
/// jamás 4xx (ADR-0012 §4).
struct RepoQueLanza: GastoRepositorio, Membresia {
    struct BDCaida: Error {}
    func respuestaPrevia(actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura? { throw BDCaida() }
    func guardar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura { throw BDCaida() }
    func gastos(de tripId: String) async throws -> [GastoConEtag] { throw BDCaida() }
    func gasto(id: String, en tripId: String) async throws -> GastoConEtag? { throw BDCaida() }
    func actualizar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura { throw BDCaida() }
    func eliminar(id: String, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura { throw BDCaida() }
    func esMiembro(_ miembro: MiembroId, de tripId: String) async throws -> Bool { throw BDCaida() }
    func viajeCerrado(_ tripId: String) async throws -> Bool { throw BDCaida() }
}

/// Simula la carrera con otro dispositivo del mismo usuario: `in_flight`. El endpoint
/// debe responder 503 (transitorio), nunca 409 (contrato §0).
struct RepoInFlight: GastoRepositorio, Membresia {
    func respuestaPrevia(actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura? { nil }
    func guardar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura { .rechazado(razon: "in_flight") }
    func gastos(de tripId: String) async throws -> [GastoConEtag] { [] }
    func gasto(id: String, en tripId: String) async throws -> GastoConEtag? { nil }
    func actualizar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura { .rechazado(razon: "in_flight") }
    func eliminar(id: String, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura { .rechazado(razon: "in_flight") }
    func esMiembro(_ miembro: MiembroId, de tripId: String) async throws -> Bool { true }
    func viajeCerrado(_ tripId: String) async throws -> Bool { false }
}

extension RepoQueLanza: SettlementRepositorio {
    func crear(_ settlement: Settlement) async throws -> ResultadoSettle { throw BDCaida() }
    func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement,
                      por actor: MiembroId, ahora: Date, rejectReason: String?) async throws -> ResultadoTransicion { throw BDCaida() }
    func confirmados(de tripId: String) async throws -> [Settlement] { throw BDCaida() }
    func pendientes(de tripId: String) async throws -> [(String, Settlement)] { throw BDCaida() }
    func settlement(id: String, en tripId: String) async throws -> Settlement? { throw BDCaida() }
}

extension RepoInFlight: SettlementRepositorio {
    func crear(_ settlement: Settlement) async throws -> ResultadoSettle { .rechazado(razon: "in_flight") }
    func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement,
                      por actor: MiembroId, ahora: Date, rejectReason: String?) async throws -> ResultadoTransicion { .estadoInvalido }
    func confirmados(de tripId: String) async throws -> [Settlement] { [] }
    func pendientes(de tripId: String) async throws -> [(String, Settlement)] { [] }
    func settlement(id: String, en tripId: String) async throws -> Settlement? { nil }
}
