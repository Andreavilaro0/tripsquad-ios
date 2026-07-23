import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

// El POST /settlements se retiró a propósito: la semántica de escritura pasa a ser
// "pendiente + confirmación de la contraparte" (decisión 2026-07-23, ADR-0017 en curso),
// que supersede a ADR-0016 §c. Se re-añade con el diseño del flujo de confirmación.
// La fontanería de escritura (SettlementRepositorio, CasosDeUsoSettle.registrarPago) se
// conserva como primitiva de dominio, sin superficie HTTP todavía.

func montarSettle(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // GET sugerencia — lectura autorizada (ADR-0016 a).
    router.get("trips/:tripId/settlement/suggestion") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let gastos = try await deps.repo.gastos(de: tripId).map(\.gasto)
        let saldos = try balances(gastos)
        switch try await deps.casosSettle.sugerirPago(tripId: tripId, actor: ctx.actor, saldos: saldos) {
        case .rechazado(let razon):
            return errorJSON(.forbidden, razon)
        case .ok(let transfers):
            let items = transfers.map { #"{"from":"\#($0.de.raw)","to":"\#($0.a.raw)","amountMinor":\#($0.importeMinor)}"# }
            let body = #"{"transfers":[\#(items.joined(separator: ","))]}"#
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: .init(string: body)))
        }
    }
}
