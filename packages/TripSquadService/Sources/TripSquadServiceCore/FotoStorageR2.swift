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
// (Context7-verificada, /durch/rust-s3 §signing + /taylorfinnell/awscr-s3
// §presigned form):
//   - Derivación de clave: kDate=HMAC("AWS4"+secret, yyyymmdd) →
//     kRegion=HMAC(kDate, region) → kService=HMAC(kRegion,"s3") →
//     kSigning=HMAC(kService,"aws4_request").
//   - Presigned POST: se FIRMA el policy document base64 —
//     signature = hex(HMAC(kSigning, base64(policy))). El cap de tamaño se
//     codifica como la condición `["content-length-range", 0, N]` de la policy:
//     ES el mecanismo por el que S3/R2 RECHAZA en el borde una subida mayor que
//     `N` (un PUT prefirmado NO puede imponer esto — por eso NO se usa aquí).
//   - Presigned GET/DELETE (URL con auth en query): canonical request → string
//     to sign (`AWS4-HMAC-SHA256\n<amzDate>\n<scope>\n<hash(canonical)>`) →
//     signature = hex(HMAC(kSigning, stringToSign)).
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
    /// DURO del `content-length-range`, se combina con el tamaño declarado por el
    /// cliente (`min`), así que la policy nunca autoriza más que el menor de los
    /// dos. `ahora` inyectable para firmas deterministas en test (hora fija).
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

    // MARK: - Subida (presigned POST con policy que impone el cap)

    /// Descriptor de un presigned POST: el cliente hace un `multipart/form-data`
    /// POST a `url` con TODOS los `fields` (incluida la foto en el campo `file`,
    /// que debe ir el ÚLTIMO). Es lo que devuelve `urlDeSubida` serializado a
    /// JSON — el dominio lo trata como String opaco (ver puerto).
    public struct DescriptorPresignedPost: Codable, Equatable, Sendable {
        public let url: String
        public let fields: [String: String]
    }

    public func urlDeSubida(storageKey: String, contentType: String, sizeBytes: Int, expiraEn: TimeInterval) async throws -> String {
        let instante = ahora()
        let amzDate = Self.amzDate(instante)
        let datestamp = Self.datestamp(instante)
        let credencial = "\(accessKey)/\(datestamp)/\(region)/s3/aws4_request"
        // Techo DURO: nunca más que el menor de (tamaño declarado, 20 MB). El caso de
        // uso ya rechaza > 20 MB antes de llegar aquí; este `min` es defensa en
        // profundidad para que la policy jamás autorice por encima del tope real.
        let tope = max(0, min(sizeBytes, maxBytes))
        let expiracion = Self.iso8601(instante.addingTimeInterval(expiraEn))

        // La policy se construye a mano (bytes exactos): la firma es sobre el
        // base64 de ESTA cadena; un JSONEncoder podría reordenar/escapar y romper
        // la correspondencia firma↔policy. `content-length-range` es la condición
        // que impone el cap en el borde de R2.
        let policyJSON = """
        {"expiration":"\(expiracion)","conditions":[\
        {"bucket":"\(bucket)"},\
        {"key":"\(Self.jsonEscape(storageKey))"},\
        {"Content-Type":"\(Self.jsonEscape(contentType))"},\
        {"x-amz-algorithm":"AWS4-HMAC-SHA256"},\
        {"x-amz-credential":"\(Self.jsonEscape(credencial))"},\
        {"x-amz-date":"\(amzDate)"},\
        ["content-length-range",0,\(tope)]\
        ]}
        """
        let policyB64 = Data(policyJSON.utf8).base64EncodedString()
        let signingKey = Self.signingKey(secret: secretKey, datestamp: datestamp, region: region)
        let firma = Self.hexHMAC(key: signingKey, data: Array(policyB64.utf8))

        let descriptor = DescriptorPresignedPost(
            url: "https://\(host)/\(bucket)",
            fields: [
                "key": storageKey,
                "Content-Type": contentType,
                "x-amz-algorithm": "AWS4-HMAC-SHA256",
                "x-amz-credential": credencial,
                "x-amz-date": amzDate,
                "policy": policyB64,
                "x-amz-signature": firma,
            ]
        )
        // Claves ordenadas: el envelope {url, fields} debe ser DETERMINISTA (mismos
        // inputs → misma cadena). El orden de las claves de `fields` ([String:String])
        // es cosmético para R2 (el cliente las lee por nombre), pero sin `.sortedKeys`
        // el Dictionary de Swift las serializa en orden no determinista por proceso.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(descriptor), as: UTF8.self)
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

    private func urlPrefirmadaQuery(metodo: String, storageKey: String, expiraEn: TimeInterval) -> String {
        let instante = ahora()
        let amzDate = Self.amzDate(instante)
        let datestamp = Self.datestamp(instante)
        let scope = "\(datestamp)/\(region)/s3/aws4_request"
        let credencial = "\(accessKey)/\(scope)"
        // Path-style: /<bucket>/<key>. Cada segmento URI-encoded, sin encodear la '/'.
        let canonicalUri = "/" + Self.uriEncode(bucket, encodeSlash: true) + "/" + Self.uriEncode(storageKey, encodeSlash: false)

        // Query canónica: pares ORDENADOS por clave, ambos lados URI-encoded (la '/'
        // del credencial SÍ se encodea en query).
        let pares: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", credencial),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(Int(expiraEn))),
            ("X-Amz-SignedHeaders", "host"),
        ]
        let canonicalQuery = pares
            .map { (Self.uriEncode($0.0, encodeSlash: true), Self.uriEncode($0.1, encodeSlash: true)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalHeaders = "host:\(host)\n"
        let canonicalRequest = [
            metodo,
            canonicalUri,
            canonicalQuery,
            canonicalHeaders,
            "host",
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

    /// Escape mínimo para inyectar un valor dentro del policy JSON hecho a mano
    /// (`"` y `\`). Las `storageKey`/`contentType` reales no traen caracteres de
    /// control, pero se defiende igual para no romper el JSON ni la firma.
    private static func jsonEscape(_ s: String) -> String {
        var salida = ""
        for c in s {
            switch c {
            case "\\": salida += "\\\\"
            case "\"": salida += "\\\""
            default: salida.append(c)
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
    private static func iso8601(_ d: Date) -> String { formateador("yyyy-MM-dd'T'HH:mm:ss'Z'").string(from: d) }
}
