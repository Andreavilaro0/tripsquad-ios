// Autenticación: Bearer JWT verificado contra las JWKS de Supabase (ADR-0009 §6,
// ADR-0014 §1).
//
// ⭐ La regla que manda: **el JWT AUTENTICA, nunca AUTORIZA.** De aquí sale un
// `MiembroId` y nada más. La membresía en un viaje se consulta SIEMPRE contra
// `trip_members` en el momento de uso (ADR-0014 §2); meter permisos en el token
// sería precisamente el bug que ese ADR mata.
//
// Defensas explícitas:
//   - `alg` en allow-list ES256 → mata `alg:none` y la confusión de algoritmos HS*
//     (un atacante que reusa un `kid` público como secreto HMAC).
//   - `kid` contra la JWKS: una clave desconocida no se verifica "por si acaso".
//   - `iss` y `aud` comprobados contra NUESTRA config: un token de otro proyecto
//     Supabase, o dirigido a otro servicio, no entra.
//   - `exp` obligatorio (los access tokens duran ≤ 5 min, ADR-0014 §1).

import Foundation
import AsyncHTTPClient
import JWTKit
import NIOCore
import TripSquadDomain

/// Por qué no se pudo autenticar. La distinción importa en la frontera HTTP:
/// `jwksNoDisponible` es **nuestro** fallo (transitorio → 5xx), no del cliente;
/// devolverlo como 401 haría que la app pidiera login por una caída de Supabase.
public enum ErrorAuth: Error, Equatable {
    case sinCabecera          // no hay `Authorization: Bearer …`
    case tokenInvalido        // firma, algoritmo, kid, iss, aud o exp incorrectos
    case jwksNoDisponible     // no se pudo obtener la JWKS (fallo nuestro)
}

/// De dónde salen las claves públicas. Se inyecta para poder testear sin red.
public protocol FuenteJWKS: Sendable {
    /// El JSON de la JWKS (`{"keys":[…]}`).
    func descargar() async throws -> String
}

/// Lo único que el servicio necesita saber hacer con un token.
public protocol VerificadorDeToken: Sendable {
    /// El miembro autenticado, a partir del valor crudo de la cabecera `Authorization`.
    func miembro(deBearer bearer: String?) async throws -> MiembroId
}

/// Los claims que nos interesan de un token de Supabase. El resto (`role`, `email`,
/// `session_id`…) se ignora a propósito: cuanto menos se lea del token, menos
/// tentación de autorizar con él.
struct ClaimsSupabase: JWTPayload {
    let iss: IssuerClaim
    let sub: SubjectClaim
    let aud: AudienceClaim
    let iat: IssuedAtClaim      // emisión: sirve para acotar la vida del token (exp-iat)
    let exp: ExpirationClaim

    func verify(using algorithm: some JWTAlgorithm) throws {
        try exp.verifyNotExpired()
    }
}

// MARK: - Verificador

/// Verifica tokens de Supabase contra su JWKS, con caché y refresco por rotación.
///
/// Es un `actor` porque la caché de claves es estado mutable compartido por todas
/// las peticiones en vuelo.
public actor VerificadorSupabase: VerificadorDeToken {

    private let fuente: FuenteJWKS
    private let issuer: String
    private let audiencia: String
    private let ttlCache: TimeInterval
    private let minEntreRefrescos: TimeInterval
    private let maxTTLToken: TimeInterval?
    private let reloj: @Sendable () -> Date

    private var claves: JWTKeyCollection?
    private var kidsConocidos: Set<String> = []
    private var descargadaEn: Date?
    private var ultimoRefrescoForzado: Date?

    /// - Parameters:
    ///   - ttlCache: cuánto vale la JWKS cacheada. Supabase documenta ~10 min.
    ///   - minEntreRefrescos: ventana mínima entre refrescos forzados por un `kid`
    ///     desconocido. Sin esto, un atacante con tokens de `kid` inventado nos
    ///     convierte en un martillo contra la JWKS de Supabase (y en un 429 nuestro).
    ///   - maxTTLToken: edad máxima admitida del token (`exp - iat`), en segundos.
    ///     Defensa en profundidad de ADR-0014 §1 ("TTL del access token ≤ 5 min"):
    ///     rechaza tokens de vida larga aunque su firma sea válida. `nil` = sin
    ///     límite. Debe cuadrar con el TTL real que emite Supabase (su defecto son
    ///     3600 s): ponerlo por debajo rechazaría tokens legítimos.
    public init(
        fuente: FuenteJWKS,
        issuer: String,
        audiencia: String,
        ttlCache: TimeInterval = 600,
        minEntreRefrescos: TimeInterval = 60,
        maxTTLToken: TimeInterval? = nil,
        reloj: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fuente = fuente
        self.issuer = issuer
        self.audiencia = audiencia
        self.ttlCache = ttlCache
        self.minEntreRefrescos = minEntreRefrescos
        self.maxTTLToken = maxTTLToken
        self.reloj = reloj
    }

    public func miembro(deBearer bearer: String?) async throws -> MiembroId {
        guard let token = Self.tokenDe(bearer) else { throw ErrorAuth.sinCabecera }

        // 1. Cabecera ANTES de tocar criptografía: allow-list de algoritmo y kid.
        let cabecera = try Self.cabecera(de: token)
        guard cabecera.alg == "ES256" else { throw ErrorAuth.tokenInvalido }
        guard let kid = cabecera.kid, !kid.isEmpty else { throw ErrorAuth.tokenInvalido }

        // 2. Claves vigentes; si el kid no está, puede ser una rotación → un refresco.
        var coleccion = try await clavesVigentes()
        if !kidsConocidos.contains(kid) {
            coleccion = try await refrescarPorKidDesconocido() ?? coleccion
            guard kidsConocidos.contains(kid) else { throw ErrorAuth.tokenInvalido }
        }

        // 3. Firma + `exp` (los comprueba JWTKit).
        let claims: ClaimsSupabase
        do {
            claims = try await coleccion.verify(token, as: ClaimsSupabase.self)
        } catch {
            throw ErrorAuth.tokenInvalido
        }

        // 4. Emisor y audiencia contra NUESTRA config, no contra lo que diga el token.
        guard claims.iss.value == issuer else { throw ErrorAuth.tokenInvalido }
        do { try claims.aud.verifyIntendedAudience(includes: audiencia) }
        catch { throw ErrorAuth.tokenInvalido }

        // 5. Edad máxima del token (ADR-0014 §1). Defensa en profundidad: aunque la
        // firma sea válida, un token de vida larga amplía la ventana en la que un JWT
        // no se puede revocar. `exp - iat` es la vida que le puso el emisor (no depende
        // del reloj local). Solo se aplica si está configurado.
        if let maxTTLToken {
            let vida = claims.exp.value.timeIntervalSince(claims.iat.value)
            guard vida <= maxTTLToken else { throw ErrorAuth.tokenInvalido }
        }

        let sub = claims.sub.value
        guard !sub.isEmpty else { throw ErrorAuth.tokenInvalido }
        return MiembroId(sub)
    }

    // MARK: Caché de claves

    private func clavesVigentes() async throws -> JWTKeyCollection {
        if let claves, let descargadaEn, reloj().timeIntervalSince(descargadaEn) <= ttlCache {
            return claves
        }
        guard let frescas = try await descargar() else { throw ErrorAuth.jwksNoDisponible }
        return frescas
    }

    /// Refresco forzado por un `kid` desconocido, limitado por ventana.
    /// Devuelve `nil` si la ventana lo impide (se sigue con lo cacheado).
    private func refrescarPorKidDesconocido() async throws -> JWTKeyCollection? {
        if let ultimo = ultimoRefrescoForzado,
           reloj().timeIntervalSince(ultimo) < minEntreRefrescos {
            return nil
        }
        ultimoRefrescoForzado = reloj()
        return try await descargar()
    }

    /// Reconstruye la colección DESDE CERO en cada descarga: una clave retirada en
    /// Supabase tiene que dejar de valer aquí, no quedarse viva en la colección.
    private func descargar() async throws -> JWTKeyCollection? {
        let json: String
        do { json = try await fuente.descargar() }
        catch { throw ErrorAuth.jwksNoDisponible }

        do {
            let coleccion = try await JWTKeyCollection().add(jwksJSON: json)
            let kids = try JSONDecoder()
                .decode(JWKSMinima.self, from: Data(json.utf8))
                .keys.compactMap(\.kid)
            claves = coleccion
            kidsConocidos = Set(kids)
            descargadaEn = reloj()
            return coleccion
        } catch {
            throw ErrorAuth.jwksNoDisponible
        }
    }

    // MARK: Parsing

    /// Solo los `kid`: de validar las claves ya se encarga JWTKit al construirlas.
    private struct JWKSMinima: Decodable {
        struct Clave: Decodable { let kid: String? }
        let keys: [Clave]
    }

    struct CabeceraJWT: Decodable {
        let alg: String
        let kid: String?
    }

    /// `Authorization: Bearer <token>` → `<token>`. Cualquier otro esquema cuenta como
    /// "sin cabecera": no vamos a intentar autenticar un Basic.
    static func tokenDe(_ bearer: String?) -> String? {
        guard let bearer else { return nil }
        let partes = bearer.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard partes.count == 2, partes[0].lowercased() == "bearer" else { return nil }
        let token = partes[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    static func cabecera(de token: String) throws -> CabeceraJWT {
        let segmentos = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segmentos.count == 3, let datos = base64url(String(segmentos[0])) else {
            throw ErrorAuth.tokenInvalido
        }
        guard let cabecera = try? JSONDecoder().decode(CabeceraJWT.self, from: datos) else {
            throw ErrorAuth.tokenInvalido
        }
        return cabecera
    }

    static func base64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }
}

// MARK: - Fuente real: la JWKS de Supabase por HTTP

/// Descarga `<supabase>/auth/v1/.well-known/jwks.json`.
public struct FuenteJWKSHTTP: FuenteJWKS {
    private let cliente: HTTPClient
    private let url: String
    private let timeout: TimeAmount

    public init(cliente: HTTPClient, url: String, timeout: TimeAmount = .seconds(5)) {
        self.cliente = cliente
        self.url = url
        self.timeout = timeout
    }

    public func descargar() async throws -> String {
        var peticion = HTTPClientRequest(url: url)
        peticion.method = .GET
        let respuesta = try await cliente.execute(peticion, timeout: timeout)
        guard respuesta.status == .ok else { throw ErrorAuth.jwksNoDisponible }
        // Tope de tamaño: una JWKS son unos cientos de bytes. 256 KiB es techo de sobra
        // y evita que una respuesta hostil nos coma la memoria.
        let cuerpo = try await respuesta.body.collect(upTo: 256 * 1024)
        return String(buffer: cuerpo)
    }
}
