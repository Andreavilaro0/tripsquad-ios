// Adaptador REAL de `FotoStorage` (TripSquadExpenses) contra Cloudflare R2
// (bead 7n3, ADR-0022 — DECISIÓN Andrea 2026-07-28: el proveedor de storage de
// fotos es R2). GATED: nunca se wirea por defecto — ver `main.swift`, solo se
// activa si `R2_ACCOUNT_ID`/`R2_ACCESS_KEY`/`R2_SECRET`/`R2_BUCKET` están en el
// entorno. NUNCA se instancia en tests con red: los tests inyectan credenciales
// falsas + una hora fija y comprueban SOLO la estructura de la firma/policy, sin
// tocar la red.
//
// Vive en TripSquadService (no en TripSquadExpenses), como
// `EstructuradorConfirmacionDeepSeek`: hace HTTP (borrado) vía AsyncHTTPClient y
// firma con swift-crypto — detalles de infraestructura que TripSquadExpenses se
// mantiene limpio de conocer (Clean Architecture, CLAUDE.md regla 5). Importa
// `TripSquadExpenses` solo para conformar el puerto.
//
// R2 habla el protocolo S3 con AWS Signature Version 4 (SigV4). Doc real
// (Context7-verificada, /websites/developers_cloudflare_r2 §"Presigned URLs"):
//   - «R2 supports presigned URLs for GET, HEAD, PUT, and DELETE HTTP methods.
//     POST requests for multipart form uploads are not currently supported.» →
//     la SUBIDA es un **presigned PUT** (NO un presigned POST con policy: R2 no
//     soporta POST, así que un POST Object sería rechazado en cada subida real).
//   - Derivación de clave: kDate=HMAC("AWS4"+secret, yyyymmdd) →
//     kRegion=HMAC(kDate, region) → kService=HMAC(kRegion,"s3") →
//     kSigning=HMAC(kService,"aws4_request").
//   - Presigned GET/PUT/DELETE (URL con auth en query): canonical request →
//     string to sign (`AWS4-HMAC-SHA256\n<amzDate>\n<scope>\n<hash(canonical)>`) →
//     signature = hex(HMAC(kSigning, stringToSign)).
//   - La SUBIDA (PUT) FIRMA `content-type` Y `content-length` como signed
//     headers (`X-Amz-SignedHeaders=content-length;content-type;host`): R2 exige
//     que el cliente envíe ESE Content-Type y ESE Content-Length exactos o la
//     firma no valida (403). R2 documenta explícitamente la restricción de
//     Content-Type en presigned PUT; el Content-Length se impone por la
//     validación de firma SigV4 estándar sobre los signed headers (R2 recomputa
//     la firma con el Content-Length REAL de la request). No hay `content-length-RANGE`
//     en un PUT (eso era exclusivo del POST policy que R2 no soporta): el tamaño
//     firmado es EXACTO (= sizeBytes), y el TECHO de 20 MB se impone en la CAPA
//     APP (el caso de uso rechaza 422 `size_invalido` y este adaptador rechaza
//     por defensa en profundidad ANTES de firmar). Ver ADR-0022 §cap.
//
// Región R2 = "auto" (constante del servicio S3 de Cloudflare). Endpoint
// path-style: `https://<accountId>.r2.cloudflarestorage.com/<bucket>/<key>`.

import AsyncHTTPClient
import Crypto
import Foundation
import NIOCore
import TripSquadExpenses

/// Abstrae la ejecución HTTP del BORRADO para poder testear sin red (mismo
/// criterio que `ClienteHTTPDeepSeek`). Firmar (subida/lectura) NO usa red, así
/// que no pasa por aquí: es puro y determinista.
public protocol ClienteHTTPR2: Sendable {
    /// DELETE a una URL ya prefirmada. Devuelve el status HTTP (para que el
    /// adaptador decida qué es éxito).
    func delete(url: String) async throws -> Int
}

/// Implementación real: AsyncHTTPClient (ya dependencia de TripSquadService).
public struct ClienteHTTPR2Real: ClienteHTTPR2 {
    private let cliente: HTTPClient
    private let timeout: TimeAmount

    public init(cliente: HTTPClient, timeout: TimeAmount = .seconds(30)) {
        self.cliente = cliente
        self.timeout = timeout
    }

    public func delete(url: String) async throws -> Int {
        var peticion = HTTPClientRequest(url: url)
        peticion.method = .DELETE
        let respuesta = try await cliente.execute(peticion, timeout: timeout)
        return Int(respuesta.status.code)
    }
}

/// Error del adaptador R2. Sin fuga de detalle del proveedor (mismo criterio
/// "sin fuga" que `ErrorEstructurador.ilegible`).
public enum ErrorFotoStorageR2: Error, Equatable, Sendable {
    /// El borrado del binario no terminó en un status aceptable (2xx/404).
    case borradoFallido(status: Int)
    /// `sizeBytes` fuera de rango (≤ 0 o > `maxBytes`) al firmar la subida. Defensa
    /// en profundidad: `CasosDeUsoFoto.presignSubida` ya rechaza (422 `size_invalido`)
    /// antes de llegar aquí, pero el adaptador NUNCA firma una subida por encima del
    /// tope — el Content-Length firmado es EXACTO, así que no se puede "recortar".
    case tamanoInvalido(sizeBytes: Int, maxBytes: Int)
}

public struct FotoStorageR2: FotoStorage {
    private let accountId: String
    private let accessKey: String
    private let secretKey: String
    private let bucket: String
    private let region: String
    private let maxBytes: Int
    private let ahora: @Sendable () -> Date
    private let httpCliente: ClienteHTTPR2

    /// `region` = "auto" en R2. `maxBytes` = 20 MB (fotos-scope.md); es el techo
    /// DURO: `urlDeSubida` RECHAZA (throw) una subida con `sizeBytes > maxBytes`
    /// ANTES de firmar (defensa en profundidad — el caso de uso ya la rechaza 422).
    /// El Content-Length firmado es EXACTO (= sizeBytes), no un rango. `ahora`
    /// inyectable para firmas deterministas en test (hora fija).
    public init(
        accountId: String,
        accessKey: String,
        secretKey: String,
        bucket: String,
        region: String = "auto",
        maxBytes: Int = 20 * 1024 * 1024,
        ahora: @escaping @Sendable () -> Date = Date.init,
        httpCliente: ClienteHTTPR2
    ) {
        self.accountId = accountId
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.bucket = bucket
        self.region = region
        self.maxBytes = maxBytes
        self.ahora = ahora
        self.httpCliente = httpCliente
    }

    private var host: String { "\(accountId).r2.cloudflarestorage.com" }

    // MARK: - Subida (presigned PUT; firma content-type + content-length)

    /// URL PUT prefirmada (SigV4 query-signed). El cliente hace `PUT <url>` con los
    /// headers `Content-Type: <contentType>` y `Content-Length: <sizeBytes>` — ambos
    /// van FIRMADOS, así que R2 exige que el cliente los envíe EXACTOS o la firma no
    /// valida (403). No devuelve JSON: el String es la URL PUT opaca (ver puerto); los
    /// headers obligatorios los reporta la ruta HTTP, que ya conoce contentType/sizeBytes.
    public func urlDeSubida(storageKey: String, contentType: String, sizeBytes: Int, expiraEn: TimeInterval) async throws -> String {
        // Techo DURO (defensa en profundidad): el caso de uso ya rechaza ≤ 0 y > 20 MB
        // (422 `size_invalido`) ANTES de llegar aquí. No se puede "recortar" el tamaño:
        // el Content-Length firmado es EXACTO (= sizeBytes) y recortarlo rompería toda
        // subida legítima — así que se RECHAZA. El cap de 20 MB vive en la capa app; R2
        // solo impone que el tamaño subido sea EXACTAMENTE el firmado (ADR-0022 §cap).
        guard sizeBytes > 0, sizeBytes <= maxBytes else {
            throw ErrorFotoStorageR2.tamanoInvalido(sizeBytes: sizeBytes, maxBytes: maxBytes)
        }
        return urlPrefirmadaQuery(
            metodo: "PUT", storageKey: storageKey, expiraEn: expiraEn,
            // Signed headers ADICIONALES a `host`: content-type y content-length. R2
            // valida la firma recomputándola con estos headers de la request → el
            // cliente DEBE mandar estos valores exactos. (`host` lo añade el helper.)
            headersFirmadosExtra: [
                ("content-length", String(sizeBytes)),
                ("content-type", contentType),
            ])
    }

    // MARK: - Lectura (presigned GET, auth en query)

    public func urlDeLectura(storageKey: String, expiraEn: TimeInterval) async throws -> String {
        urlPrefirmadaQuery(metodo: "GET", storageKey: storageKey, expiraEn: expiraEn)
    }

    // MARK: - Borrado real del binario (presigned DELETE + ejecución HTTP)

    public func borrar(storageKey: String) async throws {
        let url = urlPrefirmadaQuery(metodo: "DELETE", storageKey: storageKey, expiraEn: 60)
        let status = try await httpCliente.delete(url: url)
        // 2xx = borrado; 404 = ya no estaba → idempotente (mismo espíritu que el
        // borrado idempotente del caso de uso). Cualquier otro status es fallo.
        guard (200...299).contains(status) || status == 404 else {
            throw ErrorFotoStorageR2.borradoFallido(status: status)
        }
    }

    // MARK: - SigV4 (URL prefirmada con auth en query string)

    /// `headersFirmadosExtra`: signed headers ADICIONALES a `host` (nombre en
    /// minúsculas + valor). GET/DELETE no pasan ninguno (firman solo `host`, como
    /// siempre); PUT pasa content-type y content-length. El helper añade `host`,
    /// ordena por nombre y construye tanto `X-Amz-SignedHeaders` como los canonical
    /// headers a partir de la MISMA lista (invariante: firma ↔ SignedHeaders).
    private func urlPrefirmadaQuery(metodo: String, storageKey: String, expiraEn: TimeInterval,
                                    headersFirmadosExtra: [(nombre: String, valor: String)] = []) -> String {
        let instante = ahora()
        let amzDate = Self.amzDate(instante)
        let datestamp = Self.datestamp(instante)
        let scope = "\(datestamp)/\(region)/s3/aws4_request"
        let credencial = "\(accessKey)/\(scope)"
        // Path-style: /<bucket>/<key>. Cada segmento URI-encoded, sin encodear la '/'.
        let canonicalUri = "/" + Self.uriEncode(bucket, encodeSlash: true) + "/" + Self.uriEncode(storageKey, encodeSlash: false)

        // Signed headers ORDENADOS por nombre (host + los extra). `content-length`,
        // `content-type`, `host` ya quedan alfabéticos.
        let headersFirmados = (headersFirmadosExtra + [("host", host)]).sorted { $0.nombre < $1.nombre }
        let signedHeaders = headersFirmados.map(\.nombre).joined(separator: ";")

        // Query canónica: pares ORDENADOS por clave, ambos lados URI-encoded (la '/'
        // del credencial y el ';' de SignedHeaders SÍ se encodean en query).
        let pares: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", credencial),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(Int(expiraEn))),
            ("X-Amz-SignedHeaders", signedHeaders),
        ]
        let canonicalQuery = pares
            .map { (Self.uriEncode($0.0, encodeSlash: true), Self.uriEncode($0.1, encodeSlash: true)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        // Canonical headers: `nombre:valor\n` por cada signed header, en el MISMO orden.
        let canonicalHeaders = headersFirmados.map { "\($0.nombre):\($0.valor)\n" }.joined()
        let canonicalRequest = [
            metodo,
            canonicalUri,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Array(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(secret: secretKey, datestamp: datestamp, region: region)
        let firma = Self.hexHMAC(key: signingKey, data: Array(stringToSign.utf8))

        return "https://\(host)\(canonicalUri)?\(canonicalQuery)&X-Amz-Signature=\(firma)"
    }

    // MARK: - Primitivas SigV4 (swift-crypto)

    private static func signingKey(secret: String, datestamp: String, region: String) -> [UInt8] {
        let kDate = hmac(key: Array("AWS4\(secret)".utf8), data: Array(datestamp.utf8))
        let kRegion = hmac(key: kDate, data: Array(region.utf8))
        let kService = hmac(key: kRegion, data: Array("s3".utf8))
        return hmac(key: kService, data: Array("aws4_request".utf8))
    }

    private static func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(data), using: SymmetricKey(data: Data(key)))
        return Array(mac)
    }

    private static func hexHMAC(key: [UInt8], data: [UInt8]) -> String {
        hexEncode(hmac(key: key, data: data))
    }

    private static func sha256Hex(_ data: [UInt8]) -> String {
        hexEncode(Array(SHA256.hash(data: Data(data))))
    }

    private static func hexEncode(_ bytes: [UInt8]) -> String {
        let tabla = Array("0123456789abcdef")
        var salida = ""
        salida.reserveCapacity(bytes.count * 2)
        for b in bytes {
            salida.append(tabla[Int(b >> 4)])
            salida.append(tabla[Int(b & 0x0F)])
        }
        return salida
    }

    /// Percent-encoding RFC 3986 byte a byte (hex en MAYÚSCULAS, como exige SigV4).
    /// No se apoya en `addingPercentEncoding` para garantizar el conjunto exacto de
    /// caracteres sin reservar y el control de la '/'.
    private static func uriEncode(_ s: String, encodeSlash: Bool) -> String {
        let sinReservar = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)
        let tabla = Array("0123456789ABCDEF")
        var salida = ""
        for b in Array(s.utf8) {
            if sinReservar.contains(b) {
                salida.append(Character(UnicodeScalar(b)))
            } else if b == UInt8(ascii: "/") && !encodeSlash {
                salida.append("/")
            } else {
                salida.append("%")
                salida.append(tabla[Int(b >> 4)])
                salida.append(tabla[Int(b & 0x0F)])
            }
        }
        return salida
    }

    // MARK: - Formato de fechas (UTC, POSIX — sin dependencia de locale/tz del host)

    private static func formateador(_ formato: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = formato
        return f
    }

    private static func amzDate(_ d: Date) -> String { formateador("yyyyMMdd'T'HHmmss'Z'").string(from: d) }
    private static func datestamp(_ d: Date) -> String { formateador("yyyyMMdd").string(from: d) }
}
