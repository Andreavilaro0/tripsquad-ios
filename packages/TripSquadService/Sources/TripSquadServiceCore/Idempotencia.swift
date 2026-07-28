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
import Crypto
import Hummingbird
import HTTPTypes
import TripSquadExpenses

extension Request {
    /// SHA256 (hex) del cuerpo CRUDO de la petición (bead 5ln, ADR-0012 §2 `request_hash`).
    /// Detecta el reuso de una `Idempotency-Key` con un payload distinto (→ 422).
    ///
    /// Recoge el body ANTES de decodificarlo: `collectBody` colapsa el stream en un único
    /// `ByteBuffer` y lo RE-ALMACENA en la petición, así el `decode` posterior lo vuelve a
    /// leer. El hash se calcula sobre los bytes TAL CUAL llegan (canónico = crudo): el mismo
    /// payload reintentado por la cola offline es idéntico byte a byte, así que su hash
    /// coincide; un payload distinto con la misma clave produce un hash distinto. `mutating`
    /// porque `collectBody` reescribe `self.body`.
    mutating func hashDelCuerpo(maxBytes: Int = 4 * 1024 * 1024) async throws -> String {
        let buffer = try await collectBody(upTo: maxBytes)
        return SHA256.hash(data: Data(buffer.readableBytesView)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Respuesta de una ruta como (status, headers extra, bytes ya serializados), lista para
/// congelar. `headers` son los que van MÁS ALLÁ de `content-type` (p.ej. `etag` del create
/// de itinerario, bead 201) — se preservan también en el replay.
struct SalidaIdem: Sendable {
    let status: HTTPResponse.Status
    let headers: [String: String]
    let bytes: [UInt8]
    init(_ status: HTTPResponse.Status, _ bytes: [UInt8], headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
        self.bytes = bytes
    }
}

private func respuestaDeBytes(_ status: HTTPResponse.Status, _ bytes: [UInt8], headers: [String: String]) -> Response {
    var resp = Response(status: status, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: bytes)))
    for (nombre, valor) in headers {
        if let campo = HTTPField.Name(nombre) { resp.headers[campo] = valor }
    }
    return resp
}

// Cuerpo de error para el camino idempotente. MISMA forma que `errorJSON`
// (`{"error":{"code":...}}`) pero vía JSONEncoder (no interpolación, coherente con db0),
// para que la respuesta congelada sea idéntica a la que daría un error normal.
private struct CuerpoErrorIdem: Encodable {
    struct Codigo: Encodable { let code: String }
    let error: Codigo
}
private let jsonEncoderIdem = JSONEncoder()

/// `SalidaIdem` de una respuesta de ÉXITO ya serializada por el llamante. `headers` para
/// los que deben sobrevivir al replay (p.ej. `["etag": ...]` en el create de itinerario).
func salidaOK(_ status: HTTPResponse.Status, _ bytes: [UInt8], headers: [String: String] = [:]) -> SalidaIdem {
    SalidaIdem(status, bytes, headers: headers)
}

/// `SalidaIdem` de un error (status + code), con el body `{"error":{"code":code}}`.
func salidaError(_ status: HTTPResponse.Status, _ code: String) -> SalidaIdem {
    let data = (try? jsonEncoderIdem.encode(CuerpoErrorIdem(error: .init(code: code))))
        ?? Data(#"{"error":{"code":""}}"#.utf8)
    return SalidaIdem(status, Array(data))
}

/// Ventana de deduplicación (ADR-0012 §3, guía §175-180): 60 días. Una operación cuyo
/// `Idempotency-First-Sent` sea más antiguo se rechaza en vez de ejecutarse a ciegas.
private let ventanaDedupe: TimeInterval = 60 * 24 * 60 * 60

/// Tolerancia de desfase de reloj del cliente para un `first_sent` en el FUTURO (P2 Codex
/// #60): sin cota inferior, una fecha muy futura da una "edad" negativa que SIEMPRE pasa el
/// tope de 60 días, dejando la operación válida indefinidamente. Se acepta un pequeño
/// adelanto (relojes no perfectamente sincronizados) y se rechaza cualquier futuro mayor.
private let toleranciaFuturoReloj: TimeInterval = 5 * 60

/// Valida `Idempotency-First-Sent` (bead 5ln, guía §175-180): el cliente firma cuándo generó
/// la operación en la generación local. Devuelve un `Response` de error si la cabecera falta
/// (400), no es ISO-8601 (400), o cae fuera de la ventana de 60 días (422 `idempotency_key_expired`);
/// `nil` si es válida. Compartido por el helper genérico `conIdempotencia` y las rutas de Gastos
/// (que tienen su propio camino de idempotencia pero el MISMO contrato de cabeceras).
func errorSiFirstSentInvalido(_ req: Request, _ ahora: Date) -> Response? {
    guard let raw = req.idempotencyFirstSent() else {
        return errorJSON(.badRequest, "missing_idempotency_first_sent")
    }
    guard let firstSent = ISO8601DateFormatter().date(from: raw) else {
        return errorJSON(.badRequest, "invalid_idempotency_first_sent")
    }
    let edad = ahora.timeIntervalSince(firstSent)
    // Futuro irreal (más allá del desfase tolerado): no es un first_sent legítimo. 400 como
    // el resto de cabeceras malformadas — no 422, porque no es "caducada" sino inválida.
    guard edad >= -toleranciaFuturoReloj else {
        return errorJSON(.badRequest, "invalid_idempotency_first_sent")
    }
    guard edad <= ventanaDedupe else {
        return errorJSON(HTTPResponse.Status(code: 422), "idempotency_key_expired")
    }
    return nil
}

func conIdempotencia(
    _ req: Request,
    _ ctx: ContextoAutenticado,
    _ idem: any Idempotencia,
    _ ahora: Date,
    requestHash: String,
    _ producir: () async throws -> SalidaIdem
) async throws -> Response {
    guard let key = req.idempotencyKey() else { return errorJSON(.badRequest, "missing_idempotency_key") }
    if let err = errorSiFirstSentInvalido(req, ahora) { return err }   // bead 5ln
    switch try await idem.reclamar(actor: ctx.actor, key: key, requestHash: requestHash) {
    case .payloadDistinto:
        // Misma Idempotency-Key, payload DISTINTO (request_hash distinto) → 422 (bead 5ln,
        // ADR-0012 §2). No se reproduce a ciegas la 1ª respuesta.
        return errorJSON(HTTPResponse.Status(code: 422), "idempotency_key_mismatch")
    case .replay(let congelada):
        // `Idempotency-Result: replayed` (guía §169-174): la cola offline distingue una
        // respuesta reproducida de una ejecución fresca.
        var resp = respuestaDeBytes(HTTPResponse.Status(code: congelada.code), congelada.body, headers: congelada.headers)
        resp.headers[HTTPField.Name("idempotency-result")!] = "replayed"
        return resp
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
                                    respuesta: RespuestaCongelada(code: Int(salida.status.code),
                                                                  headers: salida.headers, body: salida.bytes))
        }
        var resp = respuestaDeBytes(salida.status, salida.bytes, headers: salida.headers)
        resp.headers[HTTPField.Name("idempotency-result")!] = "created"   // ejecución fresca
        return resp
    }
}
