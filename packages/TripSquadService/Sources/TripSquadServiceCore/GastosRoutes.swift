// Endpoints de gastos por la API DIRECTA (no la cola). Aquí SÍ se usan los códigos
// 4xx normales (412 en conflicto), a diferencia de /sync/upload (guía §0).

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

func montarGastos(_ router: Router<BasicRequestContext>, _ deps: Dependencias) {

    // POST /trips/:tripId/expenses — crear
    router.post("trips/:tripId/expenses") { req, ctx -> Response in
        guard let actor = req.actor() else { return errorJSON(.unauthorized, "not_authenticated") }
        guard let key = req.idempotencyKey() else { return errorJSON(.badRequest, "missing_idempotency_key") }
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: GastoDTO.self, context: ctx)
        let gasto = try dto.aDominio()
        let r = try await deps.casos.crear(.init(tripId: tripId, gasto: gasto, actor: actor, idempotencyKey: key))
        return respuestaDirecta(r)
    }

    // PATCH /trips/:tripId/expenses/:id — editar (If-Match obligatorio)
    router.patch("trips/:tripId/expenses/:id") { req, ctx -> Response in
        guard let actor = req.actor() else { return errorJSON(.unauthorized, "not_authenticated") }
        guard let key = req.idempotencyKey() else { return errorJSON(.badRequest, "missing_idempotency_key") }
        guard let etag = req.ifMatch() else { return errorJSON(HTTPResponse.Status(code: 428), "missing_if_match") }
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: GastoDTO.self, context: ctx)
        let gasto = try dto.aDominio()
        let r = try await deps.casos.editar(.init(tripId: tripId, gasto: gasto, actor: actor, ifMatch: etag, idempotencyKey: key))
        return respuestaDirecta(r)
    }

    // DELETE /trips/:tripId/expenses/:id — borrar (If-Match obligatorio, ADR-0013)
    router.delete("trips/:tripId/expenses/:id") { req, ctx -> Response in
        guard let actor = req.actor() else { return errorJSON(.unauthorized, "not_authenticated") }
        guard let key = req.idempotencyKey() else { return errorJSON(.badRequest, "missing_idempotency_key") }
        guard let etag = req.ifMatch() else { return errorJSON(HTTPResponse.Status(code: 428), "missing_if_match") }
        let tripId = try ctx.parameters.require("tripId")
        let id = try ctx.parameters.require("id")
        let r = try await deps.casos.eliminar(.init(tripId: tripId, gastoId: id, actor: actor, ifMatch: etag, idempotencyKey: key))
        return respuestaDirecta(r)
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
        return errorJSON(HTTPResponse.Status(code: 422), razon)
    }
}

func conEtag(_ status: HTTPResponse.Status, _ etag: String, resultado: String) -> Response {
    Response(
        status: status,
        headers: [.contentType: "application/json", HTTPField.Name("etag")!: etag,
                  HTTPField.Name("idempotency-result")!: resultado],
        body: .init(byteBuffer: .init(string: #"{"etag":"\#(etag)","result":"\#(resultado)"}"#))
    )
}

func errorJSON(_ status: HTTPResponse.Status, _ code: String) -> Response {
    var resp = Response(
        status: status,
        headers: [.contentType: "application/json", HTTPField.Name("x-error-code")!: code],
        body: .init(byteBuffer: .init(string: #"{"error":{"code":"\#(code)"}}"#))
    )
    resp.headers[.contentType] = "application/json"
    return resp
}
