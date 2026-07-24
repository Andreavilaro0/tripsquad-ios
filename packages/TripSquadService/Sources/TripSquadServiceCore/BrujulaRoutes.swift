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
// Stateless: sin persistencia propia, sin rate limiting en el MVP con stub
// (plan §Endpoint) — se añade con el adaptador real (bead).

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
        switch try await deps.casosBrujula.consultar(tripId: tripId, query: dto.query, actor: ctx.actor) {
        case .success(let respuesta):
            return try respuestaJSONBrujula(.ok, BrujulaRespuestaDTO(answer: respuesta))
        case .failure(let error):
            return respuestaErrorBrujula(error)
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
