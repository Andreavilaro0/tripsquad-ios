// Helper de ruta para la idempotencia de los POST mutantes SIN ETag (bead 379):
// chat/itinerario/votaciones/viaje. La guía de contrato (guia-contrato-openapi
// §162-168,325) exige que TODO POST mutante sea idempotente; hasta ahora solo lo
// era Gastos (vía ETag/dedupe estructural). Estos cuatro no tienen id de cliente ni
// ETag, así que se congela la RESPUESTA (código + bytes) por (actor, key) y se
// reproduce en el reintento — patrón claim-first de ADR-0012, reusando la tabla
// `idempotency_keys`.
//
// Contrato para el llamante (cada POST): DECODIFICAR el body ANTES de llamar a
// `conIdempotencia` (un body ilegible NO debe reclamar la clave), y devolver la
// respuesta como `SalidaIdem` (status + bytes ya serializados). El helper:
//   1. exige la Idempotency-Key (400 `missing_idempotency_key` si falta);
//   2. `reclamar`: si ya hay respuesta congelada → la REPRODUCE sin re-ejecutar; si
//      otra petición con la misma clave sigue en vuelo → 409 `idempotency_in_flight`;
//   3. si reclama, ejecuta el productor, congela la respuesta (solo 2xx/4xx: un 5xx
//      es transitorio y debe poder reintentarse) y la devuelve. Si el productor lanza,
//      LIBERA el reclamo para no bloquear reintentos con un 409 permanente.

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadExpenses

/// Respuesta de una ruta como (status, bytes ya serializados), lista para congelar.
struct SalidaIdem: Sendable {
    let status: HTTPResponse.Status
    let bytes: [UInt8]
    init(_ status: HTTPResponse.Status, _ bytes: [UInt8]) {
        self.status = status
        self.bytes = bytes
    }
}

private func respuestaDeBytes(_ status: HTTPResponse.Status, _ bytes: [UInt8]) -> Response {
    Response(status: status, headers: [.contentType: "application/json"],
             body: .init(byteBuffer: ByteBuffer(bytes: bytes)))
}

// Cuerpo de error para el camino idempotente. MISMA forma que `errorJSON`
// (`{"error":{"code":...}}`) pero vía JSONEncoder (no interpolación, coherente con db0),
// para que la respuesta congelada sea idéntica a la que daría un error normal.
private struct CuerpoErrorIdem: Encodable {
    struct Codigo: Encodable { let code: String }
    let error: Codigo
}
private let jsonEncoderIdem = JSONEncoder()

/// `SalidaIdem` de una respuesta de ÉXITO ya serializada por el llamante.
func salidaOK(_ status: HTTPResponse.Status, _ bytes: [UInt8]) -> SalidaIdem { SalidaIdem(status, bytes) }

/// `SalidaIdem` de un error (status + code), con el body `{"error":{"code":code}}`.
func salidaError(_ status: HTTPResponse.Status, _ code: String) -> SalidaIdem {
    let data = (try? jsonEncoderIdem.encode(CuerpoErrorIdem(error: .init(code: code))))
        ?? Data(#"{"error":{"code":""}}"#.utf8)
    return SalidaIdem(status, Array(data))
}

func conIdempotencia(
    _ req: Request,
    _ ctx: ContextoAutenticado,
    _ idem: any Idempotencia,
    _ producir: () async throws -> SalidaIdem
) async throws -> Response {
    guard let key = req.idempotencyKey() else { return errorJSON(.badRequest, "missing_idempotency_key") }
    switch try await idem.reclamar(actor: ctx.actor, key: key) {
    case .replay(let congelada):
        return respuestaDeBytes(HTTPResponse.Status(code: congelada.code), congelada.body)
    case .enVuelo:
        return errorJSON(.conflict, "idempotency_in_flight")
    case .reclamado:
        let salida: SalidaIdem
        do {
            salida = try await producir()
        } catch {
            try? await idem.liberar(actor: ctx.actor, key: key)   // no bloquear el reintento
            throw error
        }
        if salida.status.code < 500 {          // 5xx es transitorio: no se congela
            try await idem.congelar(actor: ctx.actor, key: key,
                                    respuesta: RespuestaCongelada(code: Int(salida.status.code), body: salida.bytes))
        }
        return respuestaDeBytes(salida.status, salida.bytes)
    }
}
