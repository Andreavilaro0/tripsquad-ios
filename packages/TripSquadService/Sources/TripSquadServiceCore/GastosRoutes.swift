// Endpoints de gastos por la API DIRECTA (no la cola). Aquí SÍ se usan los códigos
// 4xx normales (412 en conflicto), a diferencia de /sync/upload (guía §0).

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

// MARK: - DTOs de salida del historial (Encodable) — SIEMPRE con JSONEncoder.

private struct RevisionDTO: Encodable {
    let id: Int64
    let editedBy: String
    let editedAt: Date
    let field: String
    let oldValue: String?
    let newValue: String?
}

private struct RevisionesListDTO: Encodable { let revisions: [RevisionDTO] }

private func dtoRevisionDe(_ r: RevisionGasto) -> RevisionDTO {
    RevisionDTO(id: r.id, editedBy: r.editedBy.raw, editedAt: r.editedAt, field: r.field,
                oldValue: r.oldValue, newValue: r.newValue)
}

/// Fechas en ISO-8601 (mismo criterio que ChatRoutes/ViajeRoutes: el default de
/// JSONEncoder las serializa como epoch-double, poco útil para un cliente HTTP).
private let jsonEncoderGastos: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}()

private func respuestaJSONGastos<T: Encodable>(_ status: HTTPResponse.Status, _ valor: T) throws -> Response {
    let data = try jsonEncoderGastos.encode(valor)
    return Response(status: status, headers: [.contentType: "application/json"],
                     body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

func montarGastos(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // POST /trips/:tripId/expenses — crear
    router.post("trips/:tripId/expenses") { req, ctx -> Response in
        let actor = ctx.actor      // verificado por AuthMiddleware (ADR-0014 §1)
        guard let key = req.idempotencyKey() else { return errorJSON(.badRequest, "missing_idempotency_key") }
        if let err = errorSiFirstSentInvalido(req, deps.ahora()) { return err }   // bead 5ln
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: GastoDTO.self, context: ctx)
        let gasto = try dto.aDominio()
        let r = try await deps.casos.crear(.init(tripId: tripId, gasto: gasto, actor: actor, idempotencyKey: key))
        return respuestaDirecta(r)
    }

    // POST /trips/:tripId/expenses/from-receipt — crear gasto desde recibo itemizado
    router.post("trips/:tripId/expenses/from-receipt") { req, ctx -> Response in
        let actor = ctx.actor      // verificado por AuthMiddleware (ADR-0014 §1)
        guard let key = req.idempotencyKey() else { return errorJSON(.badRequest, "missing_idempotency_key") }
        if let err = errorSiFirstSentInvalido(req, deps.ahora()) { return err }   // bead 5ln
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: ReciboDTO.self, context: ctx)
        let items = dto.items.map { ItemRecibo(importeMinor: $0.importeMinor, sharers: $0.sharers.map(MiembroId.init)) }
        let r = try await deps.casos.crearDesdeRecibo(
            tripId: tripId, gastoId: dto.gastoId, pagadoPor: MiembroId(dto.pagadoPor),
            items: items, impuestosMinor: dto.impuestosMinor, propinaMinor: dto.propinaMinor,
            actor: actor, idempotencyKey: key)
        return respuestaDirecta(r)
    }

    // PATCH /trips/:tripId/expenses/:id — editar (If-Match obligatorio)
    router.patch("trips/:tripId/expenses/:id") { req, ctx -> Response in
        let actor = ctx.actor      // verificado por AuthMiddleware (ADR-0014 §1)
        guard let key = req.idempotencyKey() else { return errorJSON(.badRequest, "missing_idempotency_key") }
        if let err = errorSiFirstSentInvalido(req, deps.ahora()) { return err }   // bead 5ln
        guard let etag = req.ifMatch() else { return errorJSON(HTTPResponse.Status(code: 428), "missing_if_match") }
        let tripId = try ctx.parameters.require("tripId")
        let id = try ctx.parameters.require("id")
        let dto = try await req.decode(as: GastoDTO.self, context: ctx)
        // El id del path manda: el body no puede editar OTRO gasto (hallazgo P2 de Codex).
        guard dto.id == id else { return errorJSON(.badRequest, "id_mismatch") }
        let gasto = try dto.aDominio()
        let r = try await deps.casos.editar(.init(tripId: tripId, gasto: gasto, actor: actor, ifMatch: etag, idempotencyKey: key))
        return respuestaDirecta(r)
    }

    // DELETE /trips/:tripId/expenses/:id — borrar (If-Match obligatorio, ADR-0013)
    router.delete("trips/:tripId/expenses/:id") { req, ctx -> Response in
        let actor = ctx.actor      // verificado por AuthMiddleware (ADR-0014 §1)
        guard let key = req.idempotencyKey() else { return errorJSON(.badRequest, "missing_idempotency_key") }
        if let err = errorSiFirstSentInvalido(req, deps.ahora()) { return err }   // bead 5ln
        guard let etag = req.ifMatch() else { return errorJSON(HTTPResponse.Status(code: 428), "missing_if_match") }
        let tripId = try ctx.parameters.require("tripId")
        let id = try ctx.parameters.require("id")
        let r = try await deps.casos.eliminar(.init(tripId: tripId, gastoId: id, actor: actor, ifMatch: etag, idempotencyKey: key))
        return respuestaDirecta(r)
    }

    // GET /trips/:tripId/expenses/:id/revisions?limit= — historial de ediciones
    // append-only (bead p4b, ADR-0015 §15). Autorización = is_member(trip_id):
    // CUALQUIER miembro ve el historial de CUALQUIER gasto (misma función única
    // de ADR-0013 §4, coherente con "todos editan"), no hace falta ser el autor
    // ni el owner del viaje. `limit` ausente o no parseable cae al default del
    // caso de uso (50); el clamp [1,200] lo hace `CasosDeUsoGastos.revisiones`,
    // no esta ruta (mismo criterio que ChatRoutes/ItinerarioRoutes).
    router.get("trips/:tripId/expenses/:id/revisions") { req, ctx -> Response in
        let actor = ctx.actor      // verificado por AuthMiddleware (ADR-0014 §1)
        let tripId = try ctx.parameters.require("tripId")
        let id = try ctx.parameters.require("id")
        let limit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? 50
        switch try await deps.casos.revisiones(gastoId: id, tripId: tripId, actor: actor, limit: limit) {
        case .success(let revisiones):
            return try respuestaJSONGastos(.ok, RevisionesListDTO(revisions: revisiones.map(dtoRevisionDe)))
        case .failure(let error):
            return respuestaErrorGasto(error)
        }
    }
}

// MARK: - Mapeo ErrorGasto -> HTTP (ruta de historial)

private func respuestaErrorGasto(_ error: ErrorGasto) -> Response {
    switch error {
    case .noAutorizado:
        return errorJSON(.forbidden, "not_member")
    }
}

// MARK: - Mapeo ResultadoEscritura -> HTTP (camino DIRECTO)

func respuestaDirecta(_ r: ResultadoEscritura) -> Response {
    switch r {
    case .creado(let etag):
        return conEtag(.created, etag, resultado: "created")
    case .actualizado(let etag):
        return conEtag(.ok, etag, resultado: "updated")
    case .reproducido(let etag):
        return conEtag(.ok, etag ?? "", resultado: "replayed")
    case .eliminado:
        return Response(status: .noContent)               // 204, idempotente
    case .conflicto(let serverEtag):
        // API directa: el conflicto SÍ es 412 (a diferencia de la cola).
        var resp = errorJSON(.preconditionFailed, "conflict")
        resp.headers[HTTPField.Name("etag")!] = serverEtag
        return resp
    case .rechazado(let razon):
        // Rechazo de negocio permanente: 4xx en la API directa.
        //
        // (bead 55x) `not_member`/`trip_closed` NO son reglas de negocio de gastos:
        // son el mismo criterio de autorización/estado-de-viaje que los otros 7
        // módulos (Settle/Itinerario/Votación/Viaje/Foto/Reserva/Chat) — todos
        // mapean `not_member`→403 y `trip_closed`→409 (ver p.ej.
        // `respuestaErrorItinerario`/`respuestaErrorReserva`). Gastos los dejaba caer
        // en el 422 genérico junto con violaciones reales de reglas de negocio
        // (`invalid_expense`, `member_not_in_trip`, `invalid_receipt`), que sí
        // siguen siendo 422 aquí. Este switch es transversal: cubre crear, editar,
        // eliminar y from-receipt (ADR-0025), que comparten este mismo helper.
        switch razon {
        case "not_member":
            return errorJSON(.forbidden, razon)
        case "trip_closed":
            return errorJSON(.conflict, razon)
        default:
            return errorJSON(HTTPResponse.Status(code: 422), razon)
        }
    }
}

// Cuerpos de salida compartidos por TODAS las rutas (bead db0). Antes se
// interpolaban a mano —única superficie de salida que no pasaba por JSONEncoder—:
// con valores server-side (UUID/etag y códigos literales) no era explotable, pero
// en cuanto un `reglaViolada(code)` futuro llevase texto de usuario, un `"` o un `\`
// rompían el JSON. Ahora se codifican con `jsonEncoderGastos`, igual que
// `respuestaJSON` en el resto de rutas: el escaping es responsabilidad del encoder.
struct CuerpoEtagResultado: Encodable { let etag: String; let result: String }
struct CuerpoError: Encodable {
    struct Codigo: Encodable { let code: String }
    let error: Codigo
}

/// JSON del body de `conEtag`, aislado y puro para poder testearlo sin montar el
/// `Response`. El fallback (valores vacíos) es un literal estático SIN interpolación;
/// para structs de solo-String `encode` no falla nunca, así que en la práctica no se usa.
func cuerpoEtagResultadoJSON(etag: String, resultado: String) -> Data {
    (try? jsonEncoderGastos.encode(CuerpoEtagResultado(etag: etag, result: resultado)))
        ?? Data(#"{"etag":"","result":""}"#.utf8)
}

/// JSON del body de `errorJSON`, mismo criterio que `cuerpoEtagResultadoJSON`.
func cuerpoErrorJSON(_ code: String) -> Data {
    (try? jsonEncoderGastos.encode(CuerpoError(error: .init(code: code))))
        ?? Data(#"{"error":{"code":""}}"#.utf8)
}

func conEtag(_ status: HTTPResponse.Status, _ etag: String, resultado: String) -> Response {
    Response(
        status: status,
        headers: [.contentType: "application/json", HTTPField.Name("etag")!: etag,
                  HTTPField.Name("idempotency-result")!: resultado],
        body: .init(byteBuffer: ByteBuffer(bytes: cuerpoEtagResultadoJSON(etag: etag, resultado: resultado)))
    )
}

func errorJSON(_ status: HTTPResponse.Status, _ code: String) -> Response {
    Response(
        status: status,
        headers: [.contentType: "application/json", HTTPField.Name("x-error-code")!: code],
        body: .init(byteBuffer: ByteBuffer(bytes: cuerpoErrorJSON(code)))
    )
}
