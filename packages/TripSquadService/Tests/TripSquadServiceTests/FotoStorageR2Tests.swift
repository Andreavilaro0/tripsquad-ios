// Tests del adaptador REAL `FotoStorageR2` (bead 7n3, ADR-0022). DETERMINISTAS y
// SIN RED: credenciales FALSAS + una hora FIJA + un cliente HTTP que falla el test
// si se le llama. El foco es la ESTRUCTURA de la firma/policy SigV4 — en particular
// que el presigned POST codifique el `content-length-range` con el tamaño declarado
// (el mecanismo por el que R2 impone el cap en el borde), sin comprobar bytes contra
// un servidor real.

import Foundation
import Testing
@testable import TripSquadServiceCore

@Suite("FotoStorageR2: firma/policy SigV4 (bead 7n3, ADR-0022) — sin red")
struct FotoStorageR2Tests {

    // Cliente HTTP que NUNCA debe usarse: firmar subida/lectura no toca la red. Si
    // el test lo invoca, es un fallo.
    struct ClienteR2Nulo: ClienteHTTPR2 {
        func delete(url: String) async throws -> Int {
            Issue.record("la red no debe tocarse al firmar en tests")
            return 0
        }
    }

    // Hora FIJA -> firma reproducible.
    let ahoraFija = Date(timeIntervalSince1970: 1_700_000_000)

    func adaptador(maxBytes: Int = 20 * 1024 * 1024) -> FotoStorageR2 {
        let fija = ahoraFija
        return FotoStorageR2(
            accountId: "acc123", accessKey: "AKIAFAKE", secretKey: "secretofalso",
            bucket: "tripsquad-fotos", region: "auto", maxBytes: maxBytes,
            ahora: { fija }, httpCliente: ClienteR2Nulo())
    }

    /// Decodifica el descriptor JSON del presigned POST y saca la policy decodada.
    private func policyDe(_ json: String) throws -> (FotoStorageR2.DescriptorPresignedPost, [String: Any]) {
        let descriptor = try JSONDecoder().decode(
            FotoStorageR2.DescriptorPresignedPost.self, from: Data(json.utf8))
        let policyB64 = try #require(descriptor.fields["policy"])
        let policyData = try #require(Data(base64Encoded: policyB64))
        let policy = try #require(try JSONSerialization.jsonObject(with: policyData) as? [String: Any])
        return (descriptor, policy)
    }

    /// Extrae la condición `["content-length-range", 0, N]` de la policy.
    private func contentLengthRange(_ policy: [String: Any]) -> (Int, Int)? {
        guard let conditions = policy["conditions"] as? [Any] else { return nil }
        for c in conditions {
            if let arr = c as? [Any], arr.count == 3, arr[0] as? String == "content-length-range",
               let lo = arr[1] as? Int, let hi = arr[2] as? Int {
                return (lo, hi)
            }
        }
        return nil
    }

    // 1. El presigned POST incluye el content-length-range con el TAMAÑO DECLARADO,
    // fija el Content-Type, y trae credencial/date/algoritmo/firma bien formados.
    @Test func presignedPostCodificaElContentLengthRangeConElTamanoDeclarado() async throws {
        let sizeDeclarado = 5_000_000
        let json = try await adaptador().urlDeSubida(
            storageKey: "trip-1/foto-42", contentType: "image/jpeg",
            sizeBytes: sizeDeclarado, expiraEn: 900)
        let (descriptor, policy) = try policyDe(json)

        // Endpoint path-style a la cuenta/bucket de R2.
        #expect(descriptor.url == "https://acc123.r2.cloudflarestorage.com/tripsquad-fotos")

        // El cap REAL: content-length-range [0, tamañoDeclarado].
        let clr = try #require(contentLengthRange(policy))
        #expect(clr.0 == 0)
        #expect(clr.1 == sizeDeclarado)

        // El content-type queda fijado en la policy (condición) y en los fields.
        #expect(descriptor.fields["Content-Type"] == "image/jpeg")
        let conditions = try #require(policy["conditions"] as? [Any])
        let fijaContentType = conditions.contains { ($0 as? [String: Any])?["Content-Type"] as? String == "image/jpeg" }
        #expect(fijaContentType)

        // Campos SigV4 bien formados.
        #expect(descriptor.fields["x-amz-algorithm"] == "AWS4-HMAC-SHA256")
        let credencial = try #require(descriptor.fields["x-amz-credential"])
        #expect(credencial.hasPrefix("AKIAFAKE/"))
        #expect(credencial.hasSuffix("/auto/s3/aws4_request"))
        // Firma = 64 hex (HMAC-SHA256 -> 32 bytes).
        let firma = try #require(descriptor.fields["x-amz-signature"])
        #expect(firma.count == 64)
        #expect(firma.allSatisfy { $0.isHexDigit })
        // La key está en los fields (el cliente sube a esa key exacta).
        #expect(descriptor.fields["key"] == "trip-1/foto-42")
        // Caducidad presente en la policy.
        #expect(policy["expiration"] as? String != nil)
    }

    // 2. Techo DURO: un tamaño mayor que maxBytes se recorta a maxBytes (defensa en
    // profundidad — la policy nunca autoriza por encima del tope físico).
    @Test func elContentLengthRangeSeRecortaAlMaximoDuro() async throws {
        let maxBytes = 20 * 1024 * 1024
        let json = try await adaptador(maxBytes: maxBytes).urlDeSubida(
            storageKey: "t/x", contentType: "image/png",
            sizeBytes: 999_999_999, expiraEn: 900)
        let (_, policy) = try policyDe(json)
        let clr = try #require(contentLengthRange(policy))
        #expect(clr.1 == maxBytes)
    }

    // 3. La firma es DETERMINISTA con la misma hora/credenciales/entrada.
    @Test func firmaDeterministaConMismaHora() async throws {
        let a = try await adaptador().urlDeSubida(storageKey: "t/x", contentType: "image/jpeg", sizeBytes: 1024, expiraEn: 900)
        let b = try await adaptador().urlDeSubida(storageKey: "t/x", contentType: "image/jpeg", sizeBytes: 1024, expiraEn: 900)
        #expect(a == b)
    }

    // 4. urlDeLectura -> URL GET prefirmada (auth en query) con firma y expires.
    @Test func urlDeLecturaEsGetPrefirmadaConFirmaYExpires() async throws {
        let url = try await adaptador().urlDeLectura(storageKey: "trip-1/foto-42", expiraEn: 3600)
        #expect(url.hasPrefix("https://acc123.r2.cloudflarestorage.com/tripsquad-fotos/trip-1/foto-42?"))
        #expect(url.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
        #expect(url.contains("X-Amz-Expires=3600"))
        #expect(url.contains("X-Amz-SignedHeaders=host"))
        #expect(url.contains("X-Amz-Signature="))
        // La '/' del credencial va URL-encoded en la query (%2F).
        #expect(url.contains("X-Amz-Credential=AKIAFAKE%2F"))
    }
}
