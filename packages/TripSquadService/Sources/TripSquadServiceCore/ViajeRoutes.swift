// Endpoints HTTP de onboarding (ADR-0018): crear viaje, listar, detalle, invitar,
// unirse, salir/expulsar, cerrar. Todos pasan por el grupo AUTENTICADO — el actor
// SIEMPRE sale de `ctx.actor` (JWT verificado), nunca del body (mismo principio que
// GastosRoutes/SettleRoutes).
//
// Mapeo de errores (brief M2 Task 3): `ErrorViaje.noAutorizado`→403, `.noEncontrado`
// →404, `.viajeCerrado`→409, `.reglaViolada(code)`→422 con ese code. `noAutorizado`
// es DELIBERADAMENTE el mismo 403 tanto si el actor no es miembro como si el viaje
// no existe (CasosDeUsoViaje.detalle/invitar) — no se filtra existencia (ADR-0018).

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

// MARK: - DTOs de entrada (Decodable)

struct CrearViajeDTO: Decodable {
    let name: String
    let baseCurrency: String?
}

struct JoinDTO: Decodable {
    let code: String
}

// MARK: - DTOs de salida (Encodable) — SIEMPRE serializados con JSONEncoder, nunca a mano.

private struct ViajeCreadoDTO: Encodable { let id: String; let name: String; let baseCurrency: String }
private struct ViajeResumenDTO: Encodable { let id: String; let name: String; let baseCurrency: String; let closed: Bool }
private struct MisViajesDTO: Encodable { let trips: [ViajeResumenDTO] }
private struct MiembroDTO: Encodable { let memberId: String; let role: String }
private struct DetalleViajeDTO: Encodable { let id: String; let name: String; let members: [MiembroDTO] }
private struct InviteDTO: Encodable { let code: String; let expiresAt: Date }
private struct JoinResultDTO: Encodable { let result: String }
private struct ClosedDTO: Encodable { let closed: Bool }

/// Fechas en ISO-8601 en toda esta superficie (el default de JSONEncoder las
/// serializa como epoch-double, poco útil para un cliente HTTP).
private let jsonEncoderViajes: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}()

private func respuestaJSON<T: Encodable>(_ status: HTTPResponse.Status, _ valor: T) throws -> Response {
    let data = try jsonEncoderViajes.encode(valor)
    return Response(status: status, headers: [.contentType: "application/json"],
                     body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

func montarViajes(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // POST /trips — crear; el actor entra como owner.
    router.post("trips") { req, ctx -> Response in
        let dto = try await req.decode(as: CrearViajeDTO.self, context: ctx)
        let viaje = try await deps.casosViaje.crear(
            name: dto.name, baseCurrency: dto.baseCurrency ?? "EUR", actor: ctx.actor, ahora: deps.ahora())
        return try respuestaJSON(.created, ViajeCreadoDTO(id: viaje.id, name: viaje.name, baseCurrency: viaje.baseCurrency))
    }

    // GET /trips?limit= — los viajes de los que el actor es miembro activo.
    // `limit` ausente o no parseable cae al default del caso de uso (50) y el clamp
    // [1,200] lo hace `CasosDeUsoViaje.misViajes`, no esta ruta — mismo criterio que
    // ChatRoutes: un valor de query inválido NO se rechaza con 4xx.
    router.get("trips") { req, ctx -> Response in
        let limit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? 50
        let viajes = try await deps.casosViaje.misViajes(actor: ctx.actor, limit: limit)
        let dto = MisViajesDTO(trips: viajes.map {
            ViajeResumenDTO(id: $0.id, name: $0.name, baseCurrency: $0.baseCurrency, closed: $0.closedAt != nil)
        })
        return try respuestaJSON(.ok, dto)
    }

    // GET /trips/:id — SOLO miembros; 403 uniforme (exista o no el viaje).
    router.get("trips/:tripId") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        switch try await deps.casosViaje.detalle(tripId: tripId, actor: ctx.actor) {
        case .success(let (viaje, miembros)):
            let dto = DetalleViajeDTO(
                id: viaje.id, name: viaje.name,
                members: miembros.map { MiembroDTO(memberId: $0.0.raw, role: $0.1.rawValue) })
            return try respuestaJSON(.ok, dto)
        case .failure(let error):
            return respuestaErrorViaje(error)
        }
    }

    // POST /trips/:id/invites — cualquier miembro puede invitar; 403 si no es miembro.
    router.post("trips/:tripId/invites") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let ahora = deps.ahora()
        switch try await deps.casosViaje.invitar(tripId: tripId, actor: ctx.actor, ahora: ahora) {
        case .success(let invitacion):
            return try respuestaJSON(.created, InviteDTO(code: invitacion.code, expiresAt: invitacion.expiresAt))
        case .failure(let error):
            return respuestaErrorViaje(error)
        }
    }

    // DELETE /trips/:id/invites/:code — SOLO el owner revoca una invitación a mano
    // (ADR-0018 §4). El caso de uso existía pero no tenía ruta (P1 de la revisión
    // integrada). El actor SIEMPRE del JWT. 204 si se revocó, 404 si el code no existe
    // en ese viaje (idempotente: revocar una ya revocada sigue siendo éxito).
    router.delete("trips/:tripId/invites/:code") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let code = try ctx.parameters.require("code")
        switch try await deps.casosViaje.revocar(code: code, tripId: tripId, actor: ctx.actor, ahora: deps.ahora()) {
        case .success: return Response(status: .noContent)
        case .failure(let error): return respuestaErrorViaje(error)
        }
    }

    // POST /trips/join — el code ES la autorización para entrar.
    router.post("trips/join") { req, ctx -> Response in
        let dto = try await req.decode(as: JoinDTO.self, context: ctx)
        let resultado = try await deps.casosViaje.unirse(code: dto.code, actor: ctx.actor, ahora: deps.ahora())
        return try respuestaResultadoUnirse(resultado)
    }

    // DELETE /trips/:id/members/:memberId — memberId==actor -> salir; si no -> expulsar (solo owner).
    router.delete("trips/:tripId/members/:memberId") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let memberId = try ctx.parameters.require("memberId")
        let ahora = deps.ahora()
        let resultado: Result<Void, ErrorViaje>
        if memberId == ctx.actor.raw {
            resultado = try await deps.casosViaje.salir(tripId: tripId, actor: ctx.actor, ahora: ahora)
        } else {
            resultado = try await deps.casosViaje.expulsar(
                tripId: tripId, memberId: MiembroId(memberId), actor: ctx.actor, ahora: ahora)
        }
        switch resultado {
        case .success: return Response(status: .noContent)
        case .failure(let error): return respuestaErrorViaje(error)
        }
    }

    // POST /trips/:id/close — SOLO el owner.
    router.post("trips/:tripId/close") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        switch try await deps.casosViaje.cerrar(tripId: tripId, actor: ctx.actor, ahora: deps.ahora()) {
        case .success:
            return try respuestaJSON(.ok, ClosedDTO(closed: true))
        case .failure(let error):
            return respuestaErrorViaje(error)
        }
    }
}

// MARK: - Mapeo ErrorViaje -> HTTP

private func respuestaErrorViaje(_ error: ErrorViaje) -> Response {
    switch error {
    case .noAutorizado:
        return errorJSON(.forbidden, "not_member")
    case .noEncontrado:
        return errorJSON(.notFound, "not_found")
    case .viajeCerrado:
        return errorJSON(.conflict, "trip_closed")
    case .reglaViolada(let code):
        return errorJSON(HTTPResponse.Status(code: 422), code)
    }
}

// MARK: - Mapeo ResultadoUnirse -> HTTP

private func respuestaResultadoUnirse(_ resultado: ResultadoUnirse) throws -> Response {
    switch resultado {
    case .unido:
        return try respuestaJSON(.ok, JoinResultDTO(result: "joined"))
    case .yaMiembro:
        return try respuestaJSON(.ok, JoinResultDTO(result: "already_member"))
    case .codigoInvalido:
        return errorJSON(.notFound, "code_invalid")
    case .caducado:
        return errorJSON(.conflict, "expired")
    case .revocado:
        return errorJSON(.conflict, "revoked")
    case .viajeCerrado:
        return errorJSON(.conflict, "trip_closed")
    case .lleno:
        return errorJSON(.conflict, "full")
    }
}
