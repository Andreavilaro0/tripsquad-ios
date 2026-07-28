// Tests del adaptador REAL `FotoStorageR2` (bead 7n3, ADR-0022). DETERMINISTAS y
// SIN RED: credenciales FALSAS + una hora FIJA + un cliente HTTP que falla el test
// si se le llama. El foco es la ESTRUCTURA de la firma SigV4 de la SUBIDA — ahora un
// **presigned PUT** (R2 NO soporta POST): que la URL sea PUT prefirmada query-signed
// y que FIRME `content-type` y `content-length` como signed headers (el mecanismo por
// el que R2 exige que el cliente envíe ese Content-Type y ese Content-Length exactos),
// sin comprobar bytes contra un servidor real.

import Foundation
import Testing
@testable import TripSquadServiceCore

@Suite("FotoStorageR2: presigned PUT SigV4 (bead 7n3, ADR-0022) — sin red")
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

    /// Parte una URL prefirmada en sus parámetros de query (`clave -> valor`, con los
    /// valores tal cual, URL-encoded). El `X-Amz-Signature` va appended al final.
    private func query(_ url: String) throws -> [String: String] {
        let cola = try #require(url.split(separator: "?", maxSplits: 1).last.map(String.init))
        var salida: [String: String] = [:]
        for par in cola.split(separator: "&") {
            let kv = par.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { salida[kv[0]] = kv[1] }
        }
        return salida
    }

    // 1. urlDeSubida -> URL PUT prefirmada (auth en query) que FIRMA content-type y
    // content-length, contra el endpoint path-style cuenta/bucket/key.
    @Test func subidaEsPutPrefirmadoQueFirmaContentTypeYContentLength() async throws {
        let url = try await adaptador().urlDeSubida(
            storageKey: "trip-1/foto-42", contentType: "image/jpeg",
            sizeBytes: 5_000_000, expiraEn: 900)

        // Endpoint path-style a la cuenta/bucket/key de R2 (mismo host/estilo que la lectura).
        #expect(url.hasPrefix("https://acc123.r2.cloudflarestorage.com/tripsquad-fotos/trip-1/foto-42?"))

        let qs = try query(url)
        #expect(qs["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256")
        #expect(qs["X-Amz-Expires"] == "900")
        // Credencial: '/' URL-encoded (%2F) en la query.
        let cred = try #require(qs["X-Amz-Credential"])
        #expect(cred.hasPrefix("AKIAFAKE%2F"))
        #expect(cred.hasSuffix("%2Fauto%2Fs3%2Faws4_request"))
        // Signed headers = content-length;content-type;host (';' -> %3B). ESTE es el
        // mecanismo que hace a R2 exigir ambos headers exactos.
        #expect(qs["X-Amz-SignedHeaders"] == "content-length%3Bcontent-type%3Bhost")
        // Firma = 64 hex (HMAC-SHA256 -> 32 bytes).
        let firma = try #require(qs["X-Amz-Signature"])
        #expect(firma.count == 64)
        #expect(firma.allSatisfy { $0.isHexDigit })
    }

    // 2. La firma es DETERMINISTA con la misma hora/credenciales/entrada.
    @Test func firmaDeterministaConMismaHora() async throws {
        let a = try await adaptador().urlDeSubida(storageKey: "t/x", contentType: "image/jpeg", sizeBytes: 1024, expiraEn: 900)
        let b = try await adaptador().urlDeSubida(storageKey: "t/x", contentType: "image/jpeg", sizeBytes: 1024, expiraEn: 900)
        #expect(a == b)
    }

    // 3. Content-Length va FIRMADO y EXACTO: cambiar solo el tamaño cambia la firma
    // (R2 rechazaría una subida con otro Content-Length).
    @Test func distintoContentLengthCambiaLaFirma() async throws {
        let a = try await adaptador().urlDeSubida(storageKey: "t/x", contentType: "image/jpeg", sizeBytes: 1024, expiraEn: 900)
        let b = try await adaptador().urlDeSubida(storageKey: "t/x", contentType: "image/jpeg", sizeBytes: 2048, expiraEn: 900)
        let fa = try #require(query(a)["X-Amz-Signature"])
        let fb = try #require(query(b)["X-Amz-Signature"])
        #expect(fa != fb)
    }

    // 3b. Content-Type va FIRMADO: cambiar solo el content-type cambia la firma.
    @Test func distintoContentTypeCambiaLaFirma() async throws {
        let a = try await adaptador().urlDeSubida(storageKey: "t/x", contentType: "image/jpeg", sizeBytes: 1024, expiraEn: 900)
        let b = try await adaptador().urlDeSubida(storageKey: "t/x", contentType: "image/png", sizeBytes: 1024, expiraEn: 900)
        #expect(a != b)
    }

    // 4. Techo DURO: `sizeBytes > maxBytes` se RECHAZA (throw) ANTES de firmar —
    // no se puede recortar un Content-Length exacto (defensa en profundidad; el caso
    // de uso ya rechaza 422 antes de llegar aquí).
    @Test func sizeMayorQueMaxSeRechazaAntesDeFirmar() async throws {
        let ad = adaptador(maxBytes: 20 * 1024 * 1024)
        await #expect(throws: ErrorFotoStorageR2.self) {
            _ = try await ad.urlDeSubida(storageKey: "t/x", contentType: "image/png", sizeBytes: 999_999_999, expiraEn: 900)
        }
    }

    // 4b. `sizeBytes <= 0` también se rechaza (no se puede firmar un tamaño inválido).
    @Test func sizeNoPositivoSeRechaza() async throws {
        let ad = adaptador()
        await #expect(throws: ErrorFotoStorageR2.self) {
            _ = try await ad.urlDeSubida(storageKey: "t/x", contentType: "image/png", sizeBytes: 0, expiraEn: 900)
        }
    }

    // 5. urlDeLectura -> URL GET prefirmada (auth en query) con firma y expires. Sin
    // cambios respecto al diseño previo (R2 sí soporta GET/DELETE prefirmados).
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
