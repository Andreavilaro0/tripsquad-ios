import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

struct RegistrarPagoDTO: Codable {
    let settlementId: String
    let from: String
    let to: String
    let transferIndex: Int
    let amountMinor: Int64
}

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

    // POST registrar pago — escritura idempotente (ADR-0016 c).
    router.post("trips/:tripId/settlements") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: RegistrarPagoDTO.self, context: ctx)
        let r = try await deps.casosSettle.registrarPago(.init(
            tripId: tripId, settlementId: dto.settlementId,
            from: MiembroId(dto.from), to: MiembroId(dto.to),
            transferIndex: dto.transferIndex, amountMinor: dto.amountMinor,
            actor: ctx.actor))
        switch r {
        case .registrado:
            return Response(status: .created, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: .init(string: #"{"result":"registered"}"#)))
        case .duplicado:
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: .init(string: #"{"result":"duplicate"}"#)))
        case .rechazado(let razon):
            return errorJSON(HTTPResponse.Status(code: 422), razon)
        }
    }
}
