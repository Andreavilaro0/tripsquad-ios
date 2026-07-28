// Endpoints HTTP de itinerario (M5, ADR-0020 borrador —
// docs/design/itinerario-scope-y-plan.md; ETag/If-Match añadido por el bead
// 201). Mismo patrón que VotacionRoutes: el grupo AUTENTICADO, el actor
// SIEMPRE sale de `ctx.actor` (JWT verificado), nunca del body.
//
// Mapeo de errores (mismo criterio que VotacionRoutes/ViajeRoutes): `ErrorItinerario.
// noAutorizado`→403, `.noEncontrado`→404, `.viajeCerrado`→409, `.reglaViolada(code)`
// →422 con ese code, `.conflicto(serverEtag)`→412 con cabecera `etag` (bead 201, mismo
// criterio que gastos — ver `respuestaDirecta`/`conEtag` en GastosRoutes). `noAutorizado`
// es DELIBERADAMENTE el mismo 403 tanto si el actor no es miembro como si el tripId/itemId
// no existen (CasosDeUsoItinerario) — no se filtra existencia.
//
// ETag/If-Match (bead 201, ADR-0013 mismo criterio que gastos): POST/GET devuelven el
// etag de cada actividad (cabecera `etag` en POST, campo `etag` en el JSON de POST/GET/
// PATCH). El PATCH EXIGE `If-Match` (428 si falta) y lo compara ATÓMICAMENTE contra el
// etag actual en el repo — 412 con la cabecera `etag` del servidor si no coincide. Antes
// de este bead, dos ediciones concurrentes se pisaban en silencio (last-write-wins).
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

/// Badge compacto de reserva por actividad (bead iab, spec del wedge
/// 2026-07-25-wedge-reserva-por-persona §GET): el resumen que la vista de día pinta sin
/// tener que pedir aparte `GET /reservations`. `nil` si la actividad no es reservable.
private struct ReservaBadgeDTO: Encodable {
    let kind: String       // vuelo/hotel/coche/tren/seguro/otro
    let reserved: Int      // cuántos ya reservaron
    let total: Int         // total de responsables/participantes del aspecto reserva
    let complete: Bool     // todos reservados
}

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
    let etag: String   // bead 201: control de concurrencia optimista (ADR-0013)
    let reservation: ReservaBadgeDTO?   // bead iab: resumen de reserva para el badge (nil si no aplica)
}

private struct ItemsListDTO: Encodable { let items: [ActividadDTO] }

/// Deriva el badge del modo de reserva: en `cadaUnoElSuyo` cuenta los estados
/// `.reservado` sobre los participantes; en `unoParaTodos` es 1 responsable (reservado o no).
private func badgeDe(_ r: Reserva) -> ReservaBadgeDTO {
    let reserved: Int, total: Int
    switch r.mode {
    case .cadaUnoElSuyo(let estados):
        total = estados.count
        reserved = estados.values.filter { $0 == .reservado }.count
    case .unoParaTodos(_, let estado):
        total = 1
        reserved = estado == .reservado ? 1 : 0
    }
    return ReservaBadgeDTO(kind: r.kind.rawValue, reserved: reserved, total: total,
                           complete: total > 0 && reserved == total)
}

private func dtoDe(_ a: ActividadConEtag, reserva: Reserva? = nil) -> ActividadDTO {
    ActividadDTO(
        id: a.actividad.id, tripId: a.actividad.tripId, title: a.actividad.title, day: a.actividad.day,
        startTime: a.actividad.startTime, location: a.actividad.location, notes: a.actividad.notes,
        orderIndex: a.actividad.orderIndex, createdBy: a.actividad.createdBy.raw, etag: a.etag,
        reservation: reserva.map(badgeDe))
}

private func respuestaJSON<T: Encodable>(_ status: HTTPResponse.Status, _ valor: T) throws -> Response {
    let data = try JSONEncoder().encode(valor)
    return Response(status: status, headers: [.contentType: "application/json"],
                     body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

/// Igual que `respuestaJSON` pero añade la cabecera `etag` (bead 201, mismo
/// criterio que `conEtag` de GastosRoutes): el POST/PATCH de itinerario
/// también exponen el etag como cabecera, no solo como campo del body.
private func respuestaJSONConEtag<T: Encodable>(_ status: HTTPResponse.Status, _ valor: T, etag: String) throws -> Response {
    var resp = try respuestaJSON(status, valor)
    resp.headers[HTTPField.Name("etag")!] = etag
    return resp
}

func montarItinerario(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // POST /trips/:tripId/itinerary — cualquier miembro añade actividades (plan §1).
    // Idempotente (bead 379): exige Idempotency-Key; un reintento reproduce la respuesta
    // (incluida la cabecera `etag`) sin crear una segunda actividad.
    router.post("trips/:tripId/itinerary") { req, ctx -> Response in
        var req = req
        let tripId = try ctx.parameters.require("tripId")
        let requestHash = try await req.hashDelCuerpo()   // hash del cuerpo crudo (bead 5ln)
        let dto = try await req.decode(as: CrearItinerarioDTO.self, context: ctx)
        return try await conIdempotencia(req, ctx, deps.idempotencia, deps.ahora(), requestHash: requestHash) {
            switch try await deps.casosItinerario.crear(
                tripId: tripId, title: dto.title, day: dto.day, startTime: dto.startTime,
                location: dto.location, notes: dto.notes, orderIndex: dto.orderIndex ?? 0,
                actor: ctx.actor, ahora: deps.ahora()
            ) {
            case .success(let conEtag):
                return salidaOK(.created, Array(try JSONEncoder().encode(dtoDe(conEtag))), headers: ["etag": conEtag.etag])
            case .failure(let error):
                return salidaErrorItinerario(error)
            }
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
            // Badge de reserva por actividad (bead iab): un solo `tablero` del viaje, mapeado
            // por activityId, sin pedir aparte `GET /reservations`. Si el tablero falla (no
            // debería: el actor ya pasó el gate de `listar`), se degrada a sin-badges.
            var porActividad: [String: Reserva] = [:]
            if case .success(let reservas) = try await deps.casosReserva.tablero(tripId: tripId, actor: ctx.actor) {
                porActividad = Dictionary(reservas.map { ($0.activityId, $0) }, uniquingKeysWith: { primera, _ in primera })
            }
            return try respuestaJSON(.ok, ItemsListDTO(items: actividades.map {
                dtoDe($0, reserva: porActividad[$0.actividad.id])
            }))
        case .failure(let error):
            return respuestaErrorItinerario(error)
        }
    }

    // PATCH /trips/:tripId/itinerary/:itemId — SOLO el creador de la actividad o el
    // owner del viaje (plan §2). Body PARCIAL (ver cabecera del archivo). `If-Match`
    // OBLIGATORIO (bead 201, mismo criterio que gastos): sin él, 428 ANTES de tocar el
    // caso de uso — ni siquiera se carga la actividad, igual que `montarGastos`.
    router.patch("trips/:tripId/itinerary/:itemId") { req, ctx -> Response in
        guard let etag = req.ifMatch() else { return errorJSON(HTTPResponse.Status(code: 428), "missing_if_match") }
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
            actor: ctx.actor, ifMatch: etag, ahora: deps.ahora()
        ) {
        case .success(let conEtag):
            return try respuestaJSONConEtag(.ok, dtoDe(conEtag), etag: conEtag.etag)
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
    case .conflicto(let serverEtag):
        // Bead 201, mismo criterio que gastos (`respuestaDirecta` en GastosRoutes):
        // el `If-Match` no coincidía -> 412 con el etag SERVIDOR actual, para que el
        // cliente pueda reintentar con el valor correcto.
        var resp = errorJSON(.preconditionFailed, "conflict")
        resp.headers[HTTPField.Name("etag")!] = serverEtag
        return resp
    }
}

/// Mismo mapeo que `respuestaErrorItinerario` pero como `SalidaIdem`, para el camino
/// idempotente del POST. El create no produce `.conflicto` (eso es del PATCH con If-Match),
/// pero se cubre por exhaustividad, preservando la cabecera `etag`.
private func salidaErrorItinerario(_ error: ErrorItinerario) -> SalidaIdem {
    switch error {
    case .noAutorizado:
        return salidaError(.forbidden, "not_member")
    case .noEncontrado:
        return salidaError(.notFound, "not_found")
    case .viajeCerrado:
        return salidaError(.conflict, "trip_closed")
    case .reglaViolada(let code):
        return salidaError(HTTPResponse.Status(code: 422), code)
    case .conflicto(let serverEtag):
        return SalidaIdem(.preconditionFailed, salidaError(.preconditionFailed, "conflict").bytes,
                          headers: ["etag": serverEtag])
    }
}
