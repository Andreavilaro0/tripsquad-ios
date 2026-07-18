// POST /sync/upload — el endpoint de la cola offline (contrato bead 0cd).
//
// ⭐ REGLA DURA (guía §0): aquí NUNCA sale un 4xx (salvo 409, imposible en FIFO).
// Un 4xx congelaría la cola de PowerSync para siempre. Las ops se aplican EN ORDEN,
// cada una idempotente. Transitorio → 5xx (para, el batch se reintenta entero).
// Permanente/conflicto → se anota por-op y el batch termina en 200.

import Foundation
import Hummingbird
import TripSquadDomain
import TripSquadExpenses

struct SyncOp: Codable {
    let crudId: String
    let op: String                  // PUT | PATCH | DELETE
    let table: String
    let rowId: String
    let tripId: String
    let idempotencyKey: String
    let ifMatch: String?
    let data: GastoDTO?
}

struct SyncBatch: Codable {
    let deviceId: String
    let ops: [SyncOp]
}

struct SyncResult: Codable {
    let crudId: String
    let outcome: String             // accepted | replayed | rejected | conflict
    var etag: String?
    var reason: String?
    var serverEtag: String?
}

func montarSyncUpload(_ router: Router<BasicRequestContext>, _ deps: Dependencias) {
    router.post("sync/upload") { req, ctx -> Response in
        // Auth: un 401 lo maneja el connector re-autenticando (contrato §0). Es la
        // única 4xx admitida, y el cliente NO la trata como congelación de cola.
        guard let actor = req.actor() else { return json(.unauthorized, #"{"error":"reauth"}"#) }
        let batch = try await req.decode(as: SyncBatch.self, context: ctx)

        var results: [SyncResult] = []
        for op in batch.ops {
            let r: ResultadoEscritura
            do {
                r = try await aplicar(op, actor: actor, deps: deps)
            } catch {
                // Error transitorio (BD caída, decode) → 5xx, PARA. El SDK reintenta
                // el batch entero; lo ya aplicado se replaya (idempotencia).
                return json(.internalServerError, #"{"error":"transient"}"#)
            }
            // `in_flight` es transitorio: 5xx, no 409 (contrato §0).
            if case .rechazado(let razon) = r, razon == "in_flight" {
                return json(.serviceUnavailable, #"{"error":"in_flight"}"#)
            }
            results.append(desenlace(op.crudId, r))
        }

        // 200 ⟺ toda op tiene resultado. Nunca hay 200 parcial (contrato §3).
        let body = try JSONEncoder().encode(["results": results])
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: .init(bytes: Array(body))))
    }
}

// Un error de VALIDACIÓN del DTO (divisa no soportada, decimal inválido, reparto
// malo) es PERMANENTE → se devuelve como `rejected` por-op (hallazgo P1 de Codex),
// nunca como 5xx: un 5xx haría reintentar el batch para siempre y congelaría la
// cola. Solo los errores de BD (que lanza el adaptador) suben como transitorios.
private func aplicar(_ op: SyncOp, actor: MiembroId, deps: Dependencias) async throws -> ResultadoEscritura {
    switch op.op {
    case "PUT":
        guard let dto = op.data else { return .rechazado(razon: "missing_data") }
        let gasto: Gasto
        do { gasto = try dto.aDominio() } catch { return .rechazado(razon: "invalid_expense") }
        return try await deps.casos.crear(.init(tripId: op.tripId, gasto: gasto,
                                                actor: actor, idempotencyKey: op.idempotencyKey))
    case "PATCH":
        guard let dto = op.data, let etag = op.ifMatch else { return .rechazado(razon: "missing_if_match") }
        let gasto: Gasto
        do { gasto = try dto.aDominio() } catch { return .rechazado(razon: "invalid_expense") }
        return try await deps.casos.editar(.init(tripId: op.tripId, gasto: gasto,
                                                 actor: actor, ifMatch: etag, idempotencyKey: op.idempotencyKey))
    case "DELETE":
        guard let etag = op.ifMatch else { return .rechazado(razon: "missing_if_match") }
        return try await deps.casos.eliminar(.init(tripId: op.tripId, gastoId: op.rowId,
                                                   actor: actor, ifMatch: etag, idempotencyKey: op.idempotencyKey))
    default:
        return .rechazado(razon: "unknown_op")
    }
}

private func desenlace(_ crudId: String, _ r: ResultadoEscritura) -> SyncResult {
    switch r {
    case .creado(let e), .actualizado(let e):
        return SyncResult(crudId: crudId, outcome: "accepted", etag: e)
    case .reproducido(let e):
        return SyncResult(crudId: crudId, outcome: "replayed", etag: e)
    case .eliminado:
        return SyncResult(crudId: crudId, outcome: "accepted")
    case .conflicto(let s):
        // Se anota y continúa; también iría a write_conflicts (server-side).
        return SyncResult(crudId: crudId, outcome: "conflict", serverEtag: s)
    case .rechazado(let razon):
        // Se anota y continúa; también iría a write_rejections (server-side).
        return SyncResult(crudId: crudId, outcome: "rejected", reason: razon)
    }
}

private func json(_ status: HTTPResponse.Status, _ body: String) -> Response {
    Response(status: status, headers: [.contentType: "application/json"],
             body: .init(byteBuffer: .init(string: body)))
}
