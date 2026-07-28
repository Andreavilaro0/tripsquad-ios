// Endpoint HTTP de la Brújula IA (M8 Task 2, ADR-0023 borrador —
// docs/design/brujula-plan-stub.md). Mismo patrón que ChatRoutes/FotoRoutes:
// el grupo AUTENTICADO, el actor SIEMPRE sale de `ctx.actor` (JWT
// verificado), nunca del body.
//
// Mapeo de errores (mismo criterio que ChatRoutes/ItinerarioRoutes):
// `ErrorBrujula.noAutorizado`→403 sin fuga (mismo error tanto si el actor no
// es miembro como si el tripId no existe), `.reglaViolada(code)`→422 con ese
// code (query vacía o >500 caracteres).
//
// Rate-limit por usuario/viaje/día: NO vive aquí, sino en el adaptador real
// `AsistenteDeepSeek` (con el stub no hay gasto que acotar). Esta ruta solo
// mapea su rechazo a 429 (ver más abajo). El límite de TAMAÑO del body sí es
// de frontera HTTP: lo corta `LimiteTamanoBodyMiddleware` ANTES de decodificar
// (hallazgo Codex M8 #2, primera mitad), cableado en `construirRouter`.

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

// MARK: - DTOs de entrada (Decodable)

struct ConsultarBrujulaDTO: Decodable {
    let query: String
}

// MARK: - DTOs de salida (Encodable) — SIEMPRE serializados con JSONEncoder.

private struct BrujulaRespuestaDTO: Encodable {
    let answer: String
}

private let jsonEncoderBrujula: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}()

private func respuestaJSONBrujula<T: Encodable>(_ status: HTTPResponse.Status, _ valor: T) throws -> Response {
    let data = try jsonEncoderBrujula.encode(valor)
    return Response(status: status, headers: [.contentType: "application/json"],
                     body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

func montarBrujula(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // POST /trips/:tripId/brujula — SOLO miembros consultan (plan §Endpoint,
    // "403 no-miembro"). La respuesta es una sugerencia, nunca ejecuta
    // escrituras (ADR-0023 provisional).
    router.post("trips/:tripId/brujula") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: ConsultarBrujulaDTO.self, context: ctx)
        do {
            switch try await deps.casosBrujula.consultar(tripId: tripId, query: dto.query, actor: ctx.actor) {
            case .success(let respuesta):
                return try respuestaJSONBrujula(.ok, BrujulaRespuestaDTO(answer: respuesta))
            case .failure(let error):
                return respuestaErrorBrujula(error)
            }
        } catch let error as ErrorAsistenteIA {
            // El adaptador real (DeepSeek) puede rechazar por rate-limit o fallar
            // hablando con el proveedor. Con el stub por defecto esto no ocurre.
            return respuestaErrorAsistente(error)
        }
    }
}

// MARK: - Mapeo ErrorBrujula -> HTTP

private func respuestaErrorBrujula(_ error: ErrorBrujula) -> Response {
    switch error {
    case .noAutorizado:
        return errorJSON(.forbidden, "not_member")
    case .reglaViolada(let code):
        return errorJSON(HTTPResponse.Status(code: 422), code)
    }
}

// MARK: - Mapeo ErrorAsistenteIA -> HTTP (solo con el adaptador real)

private func respuestaErrorAsistente(_ error: ErrorAsistenteIA) -> Response {
    switch error {
    case .limiteDiarioSuperado:
        return errorJSON(HTTPResponse.Status(code: 429), "rate_limited")
    case .ilegible:
        // Fallo hablando con el proveedor: 502, sin fuga de detalle del tercero.
        return errorJSON(.badGateway, "assistant_unavailable")
    }
}

// MARK: - Límite de tamaño del body (frontera HTTP, hallazgo Codex M8 #2)

/// Corta las peticiones con un body demasiado grande ANTES de decodificarlo:
/// el caso de uso ya acota la query por bytes, pero eso ocurre DESPUÉS de leer
/// y decodificar el cuerpo. Este middleware rechaza por `Content-Length` en la
/// frontera (413), evitando gastar CPU/memoria decodificando un cuerpo hostil.
/// Genérico sobre el contexto para poder montarse en cualquier grupo.
public struct LimiteTamanoBodyMiddleware<Context: RequestContext>: RouterMiddleware {
    private let maxBytes: Int

    /// - Parameter maxBytes: tope del cuerpo. Por defecto 4 KiB: la query máxima
    ///   son 500 bytes; con el sobre JSON y el escape UTF-8 esto deja ~8x de
    ///   holgura y aun así corta cualquier cuerpo desproporcionado.
    public init(maxBytes: Int = 4096) { self.maxBytes = maxBytes }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if let longitud = request.headers[.contentLength].flatMap(Int.init), longitud > maxBytes {
            return errorJSON(HTTPResponse.Status(code: 413), "payload_too_large")
        }
        return try await next(request, context)
    }
}
