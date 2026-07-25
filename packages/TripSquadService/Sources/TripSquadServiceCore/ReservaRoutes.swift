// Endpoints HTTP del wedge "quién ya reservó" (spec
// docs/superpowers/specs/2026-07-25-wedge-reserva-por-persona-design.md). Mismo patrón que
// ItinerarioRoutes: el grupo AUTENTICADO, el actor SIEMPRE sale de
// `ctx.actor` (JWT verificado), nunca del body.
//
// Mapeo de errores (mismo criterio que ItinerarioRoutes): `ErrorReserva.
// noAutorizado`→403 `not_member`, `.viajeCerrado`→409 `trip_closed`,
// `.reglaViolada(code)`→422 con ese code. `noAutorizado` es DELIBERADAMENTE
// el mismo 403 tanto si el actor no es miembro como si el tripId/activityId
// no existen (CasosDeUsoReserva) — no se filtra existencia.
//
// Decodificación de enums (`kind`, `mode`, `estado`): un valor no reconocido
// (raw value que no matchea el enum) NUNCA hace crash — se traduce a 422
// `enum_invalido`, el mismo criterio defensivo que el resto de las rutas al
// decodificar el body.

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

// MARK: - DTOs de entrada (Decodable)

struct DefinirReservaDTO: Decodable {
    let kind: String
    let mode: String
    /// Solo aplica a `mode == "cadaUnoElSuyo"`.
    let participantes: [String]?
    /// Solo aplica a `mode == "unoParaTodos"`.
    let responsable: String?
}

struct MarcarReservaDTO: Decodable {
    /// `nil` para `unoParaTodos` (el estado único no distingue miembro).
    let memberId: String?
    let estado: String
}

/// Entrada de `POST .../reservation/confirmation` (dy5): el texto libre de
/// confirmación (PDF/email pegado) que el `EstructuradorConfirmacion` (LLM)
/// estructura. Ver `CasosDeUsoReserva.registrarConfirmacion`.
struct ConfirmacionInputDTO: Decodable {
    let confirmationText: String
}

// MARK: - DTOs de salida (Encodable) — SIEMPRE serializados con JSONEncoder.

private struct EstadoMiembroDTO: Encodable {
    let memberId: String
    let estado: String
}

/// El `mode` serializa como `{ tipo: "cadaUnoElSuyo", estados: [...] }` o
/// `{ tipo: "unoParaTodos", responsable, estado }` (contrato del brief de
/// esta tarea).
private enum ModoDTO: Encodable {
    case cadaUnoElSuyo(estados: [EstadoMiembroDTO])
    case unoParaTodos(responsable: String?, estado: String)

    private enum CodingKeys: String, CodingKey {
        case tipo, estados, responsable, estado
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cadaUnoElSuyo(let estados):
            try c.encode("cadaUnoElSuyo", forKey: .tipo)
            try c.encode(estados, forKey: .estados)
        case .unoParaTodos(let responsable, let estado):
            try c.encode("unoParaTodos", forKey: .tipo)
            try c.encodeIfPresent(responsable, forKey: .responsable)
            try c.encode(estado, forKey: .estado)
        }
    }
}

private struct ReservaDTO: Encodable {
    let activityId: String
    let tripId: String
    let kind: String
    let mode: ModoDTO
}

private struct ReservasListDTO: Encodable { let items: [ReservaDTO] }

/// Salida de `POST .../reservation/confirmation`: los datos que el
/// `EstructuradorConfirmacion` extrajo (y que `registrarConfirmacion` guardó).
private struct ConfirmacionDTO: Encodable {
    let tipo: String
    let fechaISO: String?
    let numeroConfirmacion: String?
    let proveedor: String?

    init(_ c: Confirmacion) {
        tipo = c.tipo.rawValue
        fechaISO = c.fechaISO
        numeroConfirmacion = c.numeroConfirmacion
        proveedor = c.proveedor
    }
}

/// Orden estable por `memberId` en `cadaUnoElSuyo`: `ModoReserva.cadaUnoElSuyo`
/// guarda un `Dictionary` (sin orden garantizado); el body HTTP necesita un
/// array determinista.
private func dtoDe(_ r: Reserva) -> ReservaDTO {
    let modo: ModoDTO
    switch r.mode {
    case .cadaUnoElSuyo(let estados):
        let lista = estados
            .map { EstadoMiembroDTO(memberId: $0.key.raw, estado: $0.value.rawValue) }
            .sorted { $0.memberId < $1.memberId }
        modo = .cadaUnoElSuyo(estados: lista)
    case .unoParaTodos(let responsable, let estado):
        modo = .unoParaTodos(responsable: responsable?.raw, estado: estado.rawValue)
    }
    return ReservaDTO(activityId: r.activityId, tripId: r.tripId, kind: r.kind.rawValue, mode: modo)
}

private func respuestaJSON<T: Encodable>(_ status: HTTPResponse.Status, _ valor: T) throws -> Response {
    let data = try JSONEncoder().encode(valor)
    return Response(status: status, headers: [.contentType: "application/json"],
                     body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

func montarReservas(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // PUT /trips/:tripId/itinerary/:itemId/reservation — define (crea o
    // REEMPLAZA) el aspecto reserva de la actividad. SOLO el creador de la
    // actividad o el owner del viaje (gate de `CasosDeUsoReserva.definir`).
    router.put("trips/:tripId/itinerary/:itemId/reservation") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let activityId = try ctx.parameters.require("itemId")
        let dto = try await req.decode(as: DefinirReservaDTO.self, context: ctx)

        guard let kind = KindReserva(rawValue: dto.kind) else {
            return errorJSON(HTTPResponse.Status(code: 422), "enum_invalido")
        }
        let modo: ModoDefinicion
        switch dto.mode {
        case "cadaUnoElSuyo":
            modo = .cadaUnoElSuyo(participantes: (dto.participantes ?? []).map(MiembroId.init))
        case "unoParaTodos":
            modo = .unoParaTodos(responsable: dto.responsable.map(MiembroId.init))
        default:
            return errorJSON(HTTPResponse.Status(code: 422), "enum_invalido")
        }

        switch try await deps.casosReserva.definir(
            tripId: tripId, activityId: activityId, kind: kind, modo: modo,
            actor: ctx.actor, ahora: deps.ahora()
        ) {
        case .success(let reserva):
            return try respuestaJSON(.created, dtoDe(reserva))
        case .failure(let error):
            return respuestaErrorReserva(error)
        }
    }

    // DELETE /trips/:tripId/itinerary/:itemId/reservation — quita el
    // aspecto reserva. Mismo gate que `definir`. Idempotente (borrar algo que
    // no existe no es error, ver `CasosDeUsoReserva.quitar`).
    router.delete("trips/:tripId/itinerary/:itemId/reservation") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let activityId = try ctx.parameters.require("itemId")
        switch try await deps.casosReserva.quitar(
            tripId: tripId, activityId: activityId, actor: ctx.actor, ahora: deps.ahora()
        ) {
        case .success:
            return Response(status: .noContent)
        case .failure(let error):
            return respuestaErrorReserva(error)
        }
    }

    // PUT /trips/:tripId/itinerary/:itemId/reservation/status — marca el
    // estado. `cadaUnoElSuyo`: `memberId` obligatorio, el actor debe ser ESE
    // miembro o el owner. `unoParaTodos`: `memberId` debe ir ausente, el
    // actor debe ser el responsable o el owner (ver `CasosDeUsoReserva.marcar`).
    router.put("trips/:tripId/itinerary/:itemId/reservation/status") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let activityId = try ctx.parameters.require("itemId")
        let dto = try await req.decode(as: MarcarReservaDTO.self, context: ctx)

        guard let estado = EstadoReserva(rawValue: dto.estado) else {
            return errorJSON(HTTPResponse.Status(code: 422), "enum_invalido")
        }

        switch try await deps.casosReserva.marcar(
            tripId: tripId, activityId: activityId, memberId: dto.memberId.map(MiembroId.init),
            estado: estado, actor: ctx.actor, ahora: deps.ahora()
        ) {
        case .success(let reserva):
            return try respuestaJSON(.ok, dtoDe(reserva))
        case .failure(let error):
            return respuestaErrorReserva(error)
        }
    }

    // POST /trips/:tripId/itinerary/:itemId/reservation/confirmation —
    // registra la confirmación de reserva del ACTOR (dy5, spec
    // docs/superpowers/specs/2026-07-25-dy5-confirmaciones-design.md). El actor SIEMPRE sale de
    // `ctx.actor` (JWT), nunca del body. Ver `CasosDeUsoReserva.registrarConfirmacion`
    // para el gate y el mapeo `confirmacion_ilegible`.
    router.post("trips/:tripId/itinerary/:itemId/reservation/confirmation") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let itemId = try ctx.parameters.require("itemId")
        let dto = try await req.decode(as: ConfirmacionInputDTO.self, context: ctx)

        switch try await deps.casosReserva.registrarConfirmacion(
            tripId: tripId, activityId: itemId, textoConfirmacion: dto.confirmationText,
            actor: ctx.actor, ahora: deps.ahora()
        ) {
        case .success(let c):
            return try respuestaJSON(.ok, ConfirmacionDTO(c))
        case .failure(let e):
            return respuestaErrorReserva(e)
        }
    }

    // GET /trips/:tripId/reservations — el tablero. SOLO miembros del viaje
    // (403 sin fuga, mismo criterio que el resto de rutas de lectura).
    router.get("trips/:tripId/reservations") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        switch try await deps.casosReserva.tablero(tripId: tripId, actor: ctx.actor) {
        case .success(let reservas):
            return try respuestaJSON(.ok, ReservasListDTO(items: reservas.map(dtoDe)))
        case .failure(let error):
            return respuestaErrorReserva(error)
        }
    }
}

// MARK: - Mapeo ErrorReserva -> HTTP

private func respuestaErrorReserva(_ error: ErrorReserva) -> Response {
    switch error {
    case .noAutorizado:
        return errorJSON(.forbidden, "not_member")
    case .viajeCerrado:
        return errorJSON(.conflict, "trip_closed")
    case .reglaViolada(let code):
        return errorJSON(HTTPResponse.Status(code: 422), code)
    }
}
