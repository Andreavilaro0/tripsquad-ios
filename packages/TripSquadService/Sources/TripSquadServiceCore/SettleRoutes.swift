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
}
private struct SugerenciaDTO: Encodable {
    let transfers: [TransferenciaDTO]
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
        let saldos = try balances(gastos)
        let transfers = deps.casosSettle.sugerir(saldos: saldos).map {
            TransferenciaDTO(from: $0.de.raw, to: $0.a.raw, amountMinor: $0.importeMinor)
        }
        let data = try JSONEncoder().encode(SugerenciaDTO(transfers: transfers))
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
