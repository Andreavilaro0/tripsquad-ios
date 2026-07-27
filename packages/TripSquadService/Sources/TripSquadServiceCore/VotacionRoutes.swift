// Endpoints HTTP de votaciones (M4, ADR-0019 borrador —
// docs/design/votaciones-scope-y-plan.md). Mismo patrón que ViajeRoutes: el
// grupo AUTENTICADO, el actor SIEMPRE sale de `ctx.actor` (JWT verificado),
// nunca del body.
//
// Mapeo de errores (mismo criterio que ViajeRoutes/ADR-0018):
// `ErrorVotacion.noAutorizado`→403, `.noEncontrado`→404, `.viajeCerrado`→409,
// `.reglaViolada(code)`→422 con ese code. `noAutorizado` es DELIBERADAMENTE el
// mismo 403 tanto si el actor no es miembro como si el tripId/pollId no
// existen (CasosDeUsoVotacion) — no se filtra existencia.
//
// `ResultadoVotar`: `.registrado`→200, `.rechazado(razon)`→422 con `razon`
// como code (poll_not_found / poll_closed / invalid_option — ver
// RepositorioEnMemoria.votar). No es un error de autorización: el actor SÍ
// puede votar, solo que este voto en concreto se rechaza.

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

// MARK: - DTOs de entrada (Decodable)

struct CrearPollDTO: Decodable {
    let question: String
    let options: [String]
}

struct VotarDTO: Decodable {
    let choice: String
}

// MARK: - DTOs de salida (Encodable) — SIEMPRE serializados con JSONEncoder.

private struct PollDTO: Encodable {
    let id: String
    let tripId: String
    let question: String
    let options: [String]
    let closed: Bool
}

private struct PollsListDTO: Encodable { let polls: [PollDTO] }

private struct VotanteDTO: Encodable { let memberId: String; let choice: String }

private struct PollDetalleDTO: Encodable {
    let id: String
    let tripId: String
    let question: String
    let options: [String]
    let closed: Bool
    let counts: [String: Int]
    let voters: [VotanteDTO]
}

private struct VotarResultDTO: Encodable { let result: String }
private struct PollCerradaDTO: Encodable { let closed: Bool }

private func dtoDe(_ v: Votacion) -> PollDTO {
    PollDTO(id: v.id, tripId: v.tripId, question: v.question, options: v.options, closed: v.closedAt != nil)
}

private func respuestaJSON<T: Encodable>(_ status: HTTPResponse.Status, _ valor: T) throws -> Response {
    let data = try JSONEncoder().encode(valor)
    return Response(status: status, headers: [.contentType: "application/json"],
                     body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

func montarVotaciones(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // POST /trips/:tripId/polls — cualquier miembro crea (plan §1).
    // Idempotente (bead 379): exige Idempotency-Key; un reintento reproduce la respuesta
    // sin crear una segunda votación.
    router.post("trips/:tripId/polls") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: CrearPollDTO.self, context: ctx)
        return try await conIdempotencia(req, ctx, deps.idempotencia) {
            switch try await deps.casosVotacion.crear(
                tripId: tripId, question: dto.question, options: dto.options, actor: ctx.actor, ahora: deps.ahora()
            ) {
            case .success(let votacion):
                return salidaOK(.created, Array(try JSONEncoder().encode(dtoDe(votacion))))
            case .failure(let error):
                return salidaErrorVotacion(error)
            }
        }
    }

    // GET /trips/:tripId/polls?limit= — SOLO miembros (plan §5). `limit` ausente o no
    // parseable cae al default del caso de uso (50); el clamp [1,200] lo hace
    // `CasosDeUsoVotacion.listar`, no esta ruta. Mismo criterio que ChatRoutes: un
    // valor de query inválido NO se rechaza con 4xx.
    router.get("trips/:tripId/polls") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let limit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? 50
        switch try await deps.casosVotacion.listar(tripId: tripId, actor: ctx.actor, limit: limit) {
        case .success(let votaciones):
            return try respuestaJSON(.ok, PollsListDTO(polls: votaciones.map(dtoDe)))
        case .failure(let error):
            return respuestaErrorVotacion(error)
        }
    }

    // GET /trips/:tripId/polls/:pollId — SOLO miembros; conteo + votantes (plan §4).
    router.get("trips/:tripId/polls/:pollId") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let pollId = try ctx.parameters.require("pollId")
        switch try await deps.casosVotacion.detalle(pollId: pollId, tripId: tripId, actor: ctx.actor) {
        case .success(let resultado):
            let dto = PollDetalleDTO(
                id: resultado.votacion.id, tripId: resultado.votacion.tripId,
                question: resultado.votacion.question, options: resultado.votacion.options,
                closed: resultado.votacion.closedAt != nil, counts: resultado.conteo,
                voters: resultado.votos.map { VotanteDTO(memberId: $0.0.raw, choice: $0.1) })
            return try respuestaJSON(.ok, dto)
        case .failure(let error):
            return respuestaErrorVotacion(error)
        }
    }

    // POST /trips/:tripId/polls/:pollId/vote — SOLO miembros; 200 registrado / 422 razon.
    router.post("trips/:tripId/polls/:pollId/vote") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let pollId = try ctx.parameters.require("pollId")
        let dto = try await req.decode(as: VotarDTO.self, context: ctx)
        switch try await deps.casosVotacion.votar(
            pollId: pollId, tripId: tripId, choice: dto.choice, actor: ctx.actor, ahora: deps.ahora()
        ) {
        case .success(let resultado):
            return try respuestaResultadoVotar(resultado)
        case .failure(let error):
            return respuestaErrorVotacion(error)
        }
    }

    // POST /trips/:tripId/polls/:pollId/close — SOLO el creador de la poll o el owner del viaje (plan §3).
    router.post("trips/:tripId/polls/:pollId/close") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let pollId = try ctx.parameters.require("pollId")
        switch try await deps.casosVotacion.cerrar(pollId: pollId, tripId: tripId, actor: ctx.actor, ahora: deps.ahora()) {
        case .success:
            return try respuestaJSON(.ok, PollCerradaDTO(closed: true))
        case .failure(let error):
            return respuestaErrorVotacion(error)
        }
    }
}

// MARK: - Mapeo ErrorVotacion -> HTTP

private func respuestaErrorVotacion(_ error: ErrorVotacion) -> Response {
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

/// Igual que `respuestaErrorVotacion` pero como `SalidaIdem`, para el camino idempotente del POST.
private func salidaErrorVotacion(_ error: ErrorVotacion) -> SalidaIdem {
    switch error {
    case .noAutorizado:
        return salidaError(.forbidden, "not_member")
    case .noEncontrado:
        return salidaError(.notFound, "not_found")
    case .viajeCerrado:
        return salidaError(.conflict, "trip_closed")
    case .reglaViolada(let code):
        return salidaError(HTTPResponse.Status(code: 422), code)
    }
}

// MARK: - Mapeo ResultadoVotar -> HTTP

private func respuestaResultadoVotar(_ resultado: ResultadoVotar) throws -> Response {
    switch resultado {
    case .registrado:
        return try respuestaJSON(.ok, VotarResultDTO(result: "registered"))
    case .rechazado(let razon):
        return errorJSON(HTTPResponse.Status(code: 422), razon)
    }
}
