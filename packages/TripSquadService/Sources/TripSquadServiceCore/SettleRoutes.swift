import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

// El POST /settlements se retiró a propósito: la semántica de escritura pasa a ser
// "pendiente + confirmación de la contraparte" (decisión 2026-07-23, ADR-0017), que
// supersede a ADR-0016 §c. Se re-añade con el diseño del flujo de confirmación. La
// fontanería de escritura (SettlementRepositorio, CasosDeUsoSettle.registrarPago) se
// conserva como primitiva de dominio, sin superficie HTTP todavía.

// Respuesta del GET suggestion. Se serializa con JSONEncoder (finding A de la revisión
// multi-modelo): interpolar strings a mano rompe si un id trae comillas o barras.
private struct TransferenciaDTO: Encodable {
    let from: String
    let to: String
    let amountMinor: Int64
    let pending: Bool
}
private struct SugerenciaDTO: Encodable {
    let transfers: [TransferenciaDTO]
}

// --- DTOs del flujo de confirmación (ADR-0017, Task 4) ---
private struct CrearItemDTO: Decodable {
    let settlementId: String; let from: String; let to: String
    let transferIndex: Int; let amountMinor: Int64
}
private struct CrearLoteDTO: Decodable { let settlements: [CrearItemDTO] }
private struct RejectDTO: Decodable { let reason: String? }

private struct ErrDTO: Encodable { let code: String }
private struct CreadoDTO: Encodable { let id: String?; let status: String; let error: ErrDTO? }
private struct CrearRespDTO: Encodable { let created: [CreadoDTO] }
private struct EstadoDTO: Encodable { let status: String }
private struct ItemListaDTO: Encodable { let id: String; let from: String; let to: String; let amountMinor: Int64; let status: String }
private struct ListaDTO: Encodable { let settlements: [ItemListaDTO] }

private func jsonOK(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(status: status, headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

func montarSettle(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // GET sugerencia — lectura autorizada (ADR-0016 a).
    router.get("trips/:tripId/settlement/suggestion") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        // Finding D: autorizar ANTES de tocar gastos. Si el orden fuese al revés, un
        // no-miembro forzaría la lectura de un viaje ajeno y un fallo de BD daría 5xx
        // en vez del 403 exigido.
        guard try await deps.casosSettle.puedeSugerir(tripId: tripId, actor: ctx.actor) else {
            return errorJSON(.forbidden, "not_member")
        }
        let gastos = try await deps.repo.gastos(de: tripId).map(\.gasto)
        let confirmados = try await deps.casosSettle.confirmados(tripId: tripId)
        let saldos = try balancesConLiquidaciones(gastos, confirmados: confirmados)
        let transfers = deps.casosSettle.sugerir(saldos: saldos)
        // Aviso de pendientes: Set de pares [from,to] con pending en curso → O(1) por
        // transferencia en vez de O(N·M) (Gemini P2). El caso de uso ya excluye caducados.
        let paresPending = Set(try await deps.casosSettle.pendientes(tripId: tripId, ahora: deps.ahora())
            .map { [$0.1.from, $0.1.to] })
        let items = transfers.map { t -> TransferenciaDTO in
            let hayPending = paresPending.contains([t.de, t.a])
            return TransferenciaDTO(from: t.de.raw, to: t.a.raw, amountMinor: t.importeMinor, pending: hayPending)
        }
        return try jsonOK(SugerenciaDTO(transfers: items))
    }

    // POST crear-lote — afirmaciones de pago en estado pending (ADR-0017).
    router.post("trips/:tripId/settlements") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        guard try await deps.casosSettle.puedeSugerir(tripId: tripId, actor: ctx.actor) else {
            return errorJSON(.forbidden, "not_member")
        }
        let dto = try await req.decode(as: CrearLoteDTO.self, context: ctx)
        let cmds = dto.settlements.map {
            ComandoCrearPago(tripId: tripId, settlementId: $0.settlementId,
                             from: MiembroId($0.from), to: MiembroId($0.to),
                             transferIndex: $0.transferIndex, amountMinor: $0.amountMinor, actor: ctx.actor)
        }
        let resultados = try await deps.casosSettle.crearPagos(cmds, ahora: deps.ahora())
        let items = resultados.map { r -> CreadoDTO in
            switch r {
            case .creado(let id):     return CreadoDTO(id: id, status: "pending", error: nil)
            case .duplicado(let id):  return CreadoDTO(id: id, status: "duplicate", error: nil)
            case .rechazado(let raz): return CreadoDTO(id: nil, status: "rejected", error: ErrDTO(code: raz))
            }
        }
        // 201 si al menos uno se creó; si todos son rechazo/duplicado, 200.
        let algunoCreado = resultados.contains { if case .creado = $0 { return true }; return false }
        return try jsonOK(CrearRespDTO(created: items), status: algunoCreado ? .created : .ok)
    }

    router.post("trips/:tripId/settlements/:id/confirm") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId"); let id = try ctx.parameters.require("id")
        return transicionResp(try await deps.casosSettle.confirmar(id: id, en: tripId, por: ctx.actor, ahora: deps.ahora()))
    }
    router.post("trips/:tripId/settlements/:id/reject") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId"); let id = try ctx.parameters.require("id")
        let motivo = (try? await req.decode(as: RejectDTO.self, context: ctx))?.reason
        return transicionResp(try await deps.casosSettle.rechazar(id: id, en: tripId, por: ctx.actor, ahora: deps.ahora(), motivo: motivo))
    }
    router.post("trips/:tripId/settlements/:id/cancel") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId"); let id = try ctx.parameters.require("id")
        return transicionResp(try await deps.casosSettle.cancelar(id: id, en: tripId, por: ctx.actor, ahora: deps.ahora()))
    }

    // GET lista de pendientes — expuesta a través del caso de uso (no otro puerto en
    // Dependencias, decisión Task 4).
    router.get("trips/:tripId/settlements") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        guard try await deps.casosSettle.puedeSugerir(tripId: tripId, actor: ctx.actor) else {
            return errorJSON(.forbidden, "not_member")
        }
        let pend = try await deps.casosSettle.pendientes(tripId: tripId, ahora: deps.ahora())
        let items = pend.map { (id, s) in
            ItemListaDTO(id: id, from: s.from.raw, to: s.to.raw, amountMinor: s.amountMinor, status: s.status.rawValue)
        }
        return try jsonOK(ListaDTO(settlements: items))
    }
}

// POST confirm / reject / cancel — helper común de mapeo ResultadoTransicion -> HTTP.
private func transicionResp(_ r: ResultadoTransicion) -> Response {
    switch r {
    case .ok:             return (try? jsonOK(EstadoDTO(status: "ok"))) ?? errorJSON(.internalServerError, "encode")
    case .noAutorizado:   return errorJSON(.forbidden, "not_authorized")
    case .noEncontrado:   return errorJSON(.notFound, "not_found")
    case .estadoInvalido: return errorJSON(HTTPResponse.Status(code: 409), "invalid_state")
    case .caducado:       return errorJSON(HTTPResponse.Status(code: 409), "expired")
    }
}
