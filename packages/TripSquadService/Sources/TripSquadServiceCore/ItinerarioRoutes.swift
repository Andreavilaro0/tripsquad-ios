// Endpoints HTTP de itinerario (M5, ADR-0020 borrador —
// docs/design/itinerario-scope-y-plan.md). Mismo patrón que VotacionRoutes: el
// grupo AUTENTICADO, el actor SIEMPRE sale de `ctx.actor` (JWT verificado),
// nunca del body.
//
// Mapeo de errores (mismo criterio que VotacionRoutes/ViajeRoutes): `ErrorItinerario.
// noAutorizado`→403, `.noEncontrado`→404, `.viajeCerrado`→409, `.reglaViolada(code)`
// →422 con ese code. `noAutorizado` es DELIBERADAMENTE el mismo 403 tanto si el actor
// no es miembro como si el tripId/itemId no existen (CasosDeUsoItinerario) — no se
// filtra existencia.
//
// Semántica de PATCH (decisión de esta ruta, el dominio no la impone): el body es
// PARCIAL — cualquier campo ausente conserva el valor actual de la actividad. El
// dominio (`CasosDeUsoItinerario.editar`) exige un replace completo (title/day
// no-opcionales), así que aquí se carga la actividad actual ANTES de editar y se
// fusionan encima solo los campos presentes en el body. Se usa `detalle` (ya exige
// membresía, 403 sin fuga si no lo es) para esa carga en vez de exponer el
// `ItinerarioRepositorio` crudo en `Dependencias` — no añade una fuente de
// autorización nueva. (Antes se reutilizaba `listar`; desde que `listar` tiene tope,
// eso habría roto el PATCH de cualquier actividad fuera de la primera página.)
// Limitación conocida y aceptada: un campo opcional enviado
// explícitamente como `null` no se distingue de un campo ausente (ambos decodifican a
// `nil`); el plan no exige "borrar" un campo opcional, así que no se resuelve aquí.

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

// MARK: - DTOs de entrada (Decodable)

struct CrearItinerarioDTO: Decodable {
    let title: String
    let day: String
    let startTime: String?
    let location: String?
    let notes: String?
    let orderIndex: Int?
}

/// Todos los campos opcionales (semántica PATCH parcial, ver cabecera del archivo).
struct EditarItinerarioDTO: Decodable {
    let title: String?
    let day: String?
    let startTime: String?
    let location: String?
    let notes: String?
    let orderIndex: Int?
}

// MARK: - DTOs de salida (Encodable) — SIEMPRE serializados con JSONEncoder.

private struct ActividadDTO: Encodable {
    let id: String
    let tripId: String
    let title: String
    let day: String
    let startTime: String?
    let location: String?
    let notes: String?
    let orderIndex: Int
    let createdBy: String
}

private struct ItemsListDTO: Encodable { let items: [ActividadDTO] }

private func dtoDe(_ a: ActividadItinerario) -> ActividadDTO {
    ActividadDTO(
        id: a.id, tripId: a.tripId, title: a.title, day: a.day, startTime: a.startTime,
        location: a.location, notes: a.notes, orderIndex: a.orderIndex, createdBy: a.createdBy.raw)
}

private func respuestaJSON<T: Encodable>(_ status: HTTPResponse.Status, _ valor: T) throws -> Response {
    let data = try JSONEncoder().encode(valor)
    return Response(status: status, headers: [.contentType: "application/json"],
                     body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

func montarItinerario(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // POST /trips/:tripId/itinerary — cualquier miembro añade actividades (plan §1).
    router.post("trips/:tripId/itinerary") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: CrearItinerarioDTO.self, context: ctx)
        switch try await deps.casosItinerario.crear(
            tripId: tripId, title: dto.title, day: dto.day, startTime: dto.startTime,
            location: dto.location, notes: dto.notes, orderIndex: dto.orderIndex ?? 0,
            actor: ctx.actor, ahora: deps.ahora()
        ) {
        case .success(let actividad):
            return try respuestaJSON(.created, dtoDe(actividad))
        case .failure(let error):
            return respuestaErrorItinerario(error)
        }
    }

    // GET /trips/:tripId/itinerary?limit= — SOLO miembros (plan §3, "403 sin fuga").
    // Orden (day, orderIndex, id) lo garantiza el repo (`listar`, plan §4). `limit`
    // ausente o no parseable cae al default del caso de uso (50); el clamp [1,200] lo
    // hace `CasosDeUsoItinerario.listar`, no esta ruta. Mismo criterio que ChatRoutes:
    // un valor de query inválido NO se rechaza con 4xx.
    router.get("trips/:tripId/itinerary") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let limit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? 50
        switch try await deps.casosItinerario.listar(tripId: tripId, actor: ctx.actor, limit: limit) {
        case .success(let actividades):
            return try respuestaJSON(.ok, ItemsListDTO(items: actividades.map(dtoDe)))
        case .failure(let error):
            return respuestaErrorItinerario(error)
        }
    }

    // PATCH /trips/:tripId/itinerary/:itemId — SOLO el creador de la actividad o el
    // owner del viaje (plan §2). Body PARCIAL (ver cabecera del archivo).
    router.patch("trips/:tripId/itinerary/:itemId") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let itemId = try ctx.parameters.require("itemId")
        let dto = try await req.decode(as: EditarItinerarioDTO.self, context: ctx)

        // Carga la actividad actual para fusionar el body parcial. Usa `detalle` (no
        // `listar`) desde que `listar` tiene tope: buscar el item dentro de la primera
        // página habría hecho que un PATCH sobre la actividad nº 51 devolviera 403 por
        // no encontrarla. `detalle` tiene el MISMO gate (solo miembros) y el mismo
        // `.noAutorizado` sin fuga si no existe en este viaje — no se distingue de "no
        // eres el creador/owner".
        let existente: ActividadItinerario
        switch try await deps.casosItinerario.detalle(itemId: itemId, tripId: tripId, actor: ctx.actor) {
        case .success(let item): existente = item
        case .failure(let error): return respuestaErrorItinerario(error)
        }

        switch try await deps.casosItinerario.editar(
            itemId: itemId, tripId: tripId,
            title: dto.title ?? existente.title,
            day: dto.day ?? existente.day,
            startTime: dto.startTime ?? existente.startTime,
            location: dto.location ?? existente.location,
            notes: dto.notes ?? existente.notes,
            orderIndex: dto.orderIndex ?? existente.orderIndex,
            actor: ctx.actor, ahora: deps.ahora()
        ) {
        case .success(let actividad):
            return try respuestaJSON(.ok, dtoDe(actividad))
        case .failure(let error):
            return respuestaErrorItinerario(error)
        }
    }

    // DELETE /trips/:tripId/itinerary/:itemId — SOLO el creador de la actividad o el
    // owner del viaje (plan §2). No bloquea viaje cerrado (igual criterio que
    // `CasosDeUsoVotacion.cerrar`/`CasosDeUsoItinerario.borrar`, ver comentario del
    // caso de uso: una acción terminal de limpieza no es una mutación de contenido).
    router.delete("trips/:tripId/itinerary/:itemId") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let itemId = try ctx.parameters.require("itemId")
        switch try await deps.casosItinerario.borrar(
            itemId: itemId, tripId: tripId, actor: ctx.actor, ahora: deps.ahora()
        ) {
        case .success:
            return Response(status: .noContent)
        case .failure(let error):
            return respuestaErrorItinerario(error)
        }
    }
}

// MARK: - Mapeo ErrorItinerario -> HTTP

private func respuestaErrorItinerario(_ error: ErrorItinerario) -> Response {
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
