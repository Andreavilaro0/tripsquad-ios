// Endpoints HTTP de chat (M6, ADR-0021 borrador —
// docs/design/chat-scope-y-plan.md). Mismo patrón que ItinerarioRoutes/
// VotacionRoutes: el grupo AUTENTICADO, el actor SIEMPRE sale de `ctx.actor`
// (JWT verificado), nunca del body.
//
// Mapeo de errores (mismo criterio que ItinerarioRoutes/VotacionRoutes):
// `ErrorChat.noAutorizado`→403, `.noEncontrado`→404, `.reglaViolada(code)`→422
// con ese code. `noAutorizado` es DELIBERADAMENTE el mismo 403 tanto si el
// actor no es miembro, como si el tripId no existe, como si es miembro pero
// no es el autor del mensaje al borrar (CasosDeUsoChat) — no se filtra
// existencia ni pertenencia.
//
// Query params (`since`/`limit` de GET): Hummingbird expone
// `req.uri.queryParameters` como un `FlatDictionary<Substring, Substring>` —
// no hay decodificación automática a tipos, así que se parsean a mano.
// `since` ausente o no parseable a `Int64` se trata como "sin cursor" (nil,
// desde el principio); `limit` ausente o no parseable a `Int` cae al default
// del caso de uso (50) — el clamp [1,200] lo hace `CasosDeUsoChat.listar`, no
// esta ruta. Un valor de query directamente inválido no se rechaza con 400:
// mismo criterio "no hay 4xx de validación de query en GET" que el resto del
// servicio.
//
// `nextSince` (plan §Endpoints): el id del ÚLTIMO mensaje devuelto en esta
// página, para que el cliente lo use como `since` en el siguiente poll. Si la
// página viene vacía, se conserva el `since` recibido (o `0` si tampoco vino
// — `0` es un cursor seguro porque los ids reales de Postgres arrancan en 1,
// identity, así que `since=0` en la siguiente llamada equivale a "desde el
// principio").
//
// DELETE /messages/:messageId (enmienda ADR-0014 §2, bead iou): el dominio
// (`CasosDeUsoChat.borrar`) autoriza SIEMPRE la membresía del `tripId` del
// path primero (403 sin fuga si no es miembro); con eso ya verificado, un
// `messageId` inexistente EN ESE viaje (nunca existió, ya se borró, o es de
// OTRO viaje) es 204 idempotente — no `.noAutorizado`, para no romper el
// reintento de un borrado ya aplicado. `.noAutorizado` (403) solo aparece si
// el mensaje SÍ existe en este viaje pero el actor no es su autor. El único
// origen real de un 404 en esta ruta es un `:messageId` que ni siquiera
// parsea a `Int64` (no es un cursor válido en absoluto, nunca lo sería) — se
// corta ANTES de llamar al dominio, y es la única fuga aceptada: "esto no es
// un id" no es "no tienes permiso sobre ESTE mensaje".

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

// MARK: - DTOs de entrada (Decodable)

struct EnviarMensajeDTO: Decodable {
    let body: String
}

// MARK: - DTOs de salida (Encodable) — SIEMPRE serializados con JSONEncoder.

private struct MensajeCreadoDTO: Encodable {
    let id: Int64
    let author: String
    let body: String
    let createdAt: Date
}

private struct MensajeListaDTO: Encodable {
    let id: Int64
    let author: String
    let body: String
    let deleted: Bool
    let createdAt: Date
}

private struct MensajesListDTO: Encodable {
    let messages: [MensajeListaDTO]
    let nextSince: Int64
}

/// Fechas en ISO-8601 (mismo criterio que ViajeRoutes: el default de
/// JSONEncoder las serializa como epoch-double, poco útil para un cliente HTTP).
private let jsonEncoderChat: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}()

private func respuestaJSON<T: Encodable>(_ status: HTTPResponse.Status, _ valor: T) throws -> Response {
    let data = try jsonEncoderChat.encode(valor)
    return Response(status: status, headers: [.contentType: "application/json"],
                     body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

private func dtoCreadoDe(_ m: Mensaje) -> MensajeCreadoDTO {
    MensajeCreadoDTO(id: m.id, author: m.autor.raw, body: m.body, createdAt: m.createdAt)
}

/// El body de un mensaje borrado se sustituye por el marcador (plan §Decisión
/// 3) — el mensaje no desaparece de la lista, pero su contenido sí.
private func dtoListaDe(_ m: Mensaje) -> MensajeListaDTO {
    let borrado = m.deletedAt != nil
    return MensajeListaDTO(
        id: m.id, author: m.autor.raw,
        body: borrado ? Mensaje.marcadorBorrado : m.body,
        deleted: borrado, createdAt: m.createdAt)
}

func montarChat(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // POST /trips/:tripId/messages — cualquier miembro envía (plan §Decisión 1).
    // Idempotente (bead 379): exige Idempotency-Key; un reintento con la misma clave
    // reproduce la respuesta sin crear un segundo mensaje. El body se decodifica ANTES
    // de reclamar la clave (un body ilegible no debe consumir la clave).
    router.post("trips/:tripId/messages") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: EnviarMensajeDTO.self, context: ctx)
        return try await conIdempotencia(req, ctx, deps.idempotencia, deps.ahora()) {
            switch try await deps.casosChat.enviar(
                tripId: tripId, body: dto.body, actor: ctx.actor, ahora: deps.ahora()
            ) {
            case .success(let mensaje):
                return salidaOK(.created, Array(try jsonEncoderChat.encode(dtoCreadoDe(mensaje))))
            case .failure(let error):
                return salidaErrorChat(error)
            }
        }
    }

    // GET /trips/:tripId/messages?since=&limit= — SOLO miembros (plan
    // §Decisión 1, "403 sin fuga"). Orden cronológico y filtro `id > since`
    // los garantiza el repo (`mensajes`, ver Puertos.swift).
    router.get("trips/:tripId/messages") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let since = req.uri.queryParameters["since"].flatMap { Int64($0) }
        let limit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? 50
        switch try await deps.casosChat.listar(tripId: tripId, actor: ctx.actor, since: since, limit: limit) {
        case .success(let mensajes):
            let nextSince = mensajes.last?.id ?? since ?? 0
            return try respuestaJSON(.ok, MensajesListDTO(messages: mensajes.map(dtoListaDe), nextSince: nextSince))
        case .failure(let error):
            return respuestaErrorChat(error)
        }
    }

    // DELETE /trips/:tripId/messages/:messageId — SOLO el autor del mensaje
    // borra (plan §Decisión 3), ni siquiera el owner del viaje.
    router.delete("trips/:tripId/messages/:messageId") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let messageIdRaw = try ctx.parameters.require("messageId")
        // Ver cabecera del archivo: un :messageId que no parsea a Int64 no es
        // un cursor válido en absoluto, se corta con 404 ANTES del dominio.
        guard let messageId = Int64(messageIdRaw) else {
            return errorJSON(.notFound, "not_found")
        }
        switch try await deps.casosChat.borrar(
            msgId: messageId, tripId: tripId, actor: ctx.actor, ahora: deps.ahora()
        ) {
        case .success:
            return Response(status: .noContent)
        case .failure(let error):
            return respuestaErrorChat(error)
        }
    }
}

// MARK: - Mapeo ErrorChat -> HTTP

private func respuestaErrorChat(_ error: ErrorChat) -> Response {
    switch error {
    case .noAutorizado:
        return errorJSON(.forbidden, "not_member")
    case .noEncontrado:
        return errorJSON(.notFound, "not_found")
    case .reglaViolada(let code):
        return errorJSON(HTTPResponse.Status(code: 422), code)
    }
}

/// Mismo mapeo que `respuestaErrorChat` pero como `SalidaIdem` (status + code), para el
/// camino idempotente del POST — así una respuesta de error también se congela y reproduce.
private func salidaErrorChat(_ error: ErrorChat) -> SalidaIdem {
    switch error {
    case .noAutorizado:
        return salidaError(.forbidden, "not_member")
    case .noEncontrado:
        return salidaError(.notFound, "not_found")
    case .reglaViolada(let code):
        return salidaError(HTTPResponse.Status(code: 422), code)
    }
}
