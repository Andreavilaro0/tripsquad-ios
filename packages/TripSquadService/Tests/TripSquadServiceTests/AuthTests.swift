// Tests del verificador de JWT (ADR-0014 §1: el JWT AUTENTICA, nunca autoriza).
//
// Firman tokens ES256 de verdad con una clave generada en el propio test y los
// verifican contra una JWKS estática: sin red y sin mocks de criptografía. Lo único
// falso son la FUENTE de la JWKS (para contar descargas) y el RELOJ (para la caché).

import Foundation
import Testing
import JWTKit
import TripSquadDomain
@testable import TripSquadServiceCore

// MARK: - Dobles de prueba

/// Fuente de JWKS que devuelve lo que se le diga y CUENTA las descargas.
actor FuenteFalsa: FuenteJWKS {
    private var respuestas: [String]
    private(set) var descargas = 0
    var fallar = false

    init(_ respuestas: String...) { self.respuestas = respuestas }

    func descargar() async throws -> String {
        descargas += 1
        if fallar { throw ErrorAuth.jwksNoDisponible }
        // La última respuesta se repite si se pide más veces que respuestas hay.
        return respuestas.count > 1 ? respuestas.removeFirst() : respuestas[0]
    }

    func romper() { fallar = true }
}

/// Reloj controlable: la caché y el rate-limit se prueban sin dormir.
final class RelojFalso: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date = Date()) { self.t = t }
    var ahora: Date { lock.withLock { t } }
    func avanzar(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

// MARK: - Utilidades de firma

struct ClaveDePrueba {
    let kid: String
    let privada: ES256PrivateKey

    init(kid: String) {
        self.kid = kid
        self.privada = ES256PrivateKey()
    }

    /// La entrada JWK de esta clave, en el formato que sirve Supabase (base64url).
    var jwk: String {
        let p = privada.publicKey.parameters!
        func url(_ s: String) -> String {
            s.replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return #"{"kty":"EC","crv":"P-256","alg":"ES256","use":"sig","kid":"\#(kid)","x":"\#(url(p.x))","y":"\#(url(p.y))"}"#
    }
}

func jwks(_ claves: ClaveDePrueba...) -> String {
    #"{"keys":[\#(claves.map(\.jwk).joined(separator: ","))]}"#
}

let issDePrueba = "https://proyecto.supabase.co/auth/v1"
let audDePrueba = "authenticated"

/// Firma un token ES256 con la clave dada. Los claims por defecto son válidos;
/// cada test tuerce solo el que quiere probar.
func firmar(
    _ clave: ClaveDePrueba,
    sub: String = "11111111-2222-3333-4444-555555555555",
    iss: String = issDePrueba,
    aud: String = audDePrueba,
    expira: TimeInterval = 300,
    ttl: TimeInterval? = nil     // vida del token (exp-iat); por defecto = `expira`
) async throws -> String {
    let keys = JWTKeyCollection()
    await keys.add(ecdsa: clave.privada, kid: .init(string: clave.kid))
    let expDate = Date().addingTimeInterval(expira)
    let vida = ttl ?? expira                     // TTL del token = exp - iat
    let payload = ClaimsSupabase(
        iss: .init(value: iss),
        sub: .init(value: sub),
        aud: .init(value: aud),
        iat: .init(value: expDate.addingTimeInterval(-vida)),
        exp: .init(value: expDate)
    )
    return try await keys.sign(payload, kid: .init(string: clave.kid))
}

/// Construye un token con la cabecera que se le pida (para probar alg=none y la
/// confusión de algoritmos), reutilizando el payload de un token válido.
func conCabecera(_ json: String, payloadDe token: String, firma: String = "") -> String {
    func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let payload = token.split(separator: ".")[1]
    return "\(b64url(json)).\(payload).\(firma)"
}

func verificador(
    fuente: FuenteFalsa,
    reloj: RelojFalso = RelojFalso(),
    maxTTLToken: TimeInterval? = nil
) -> VerificadorSupabase {
    VerificadorSupabase(
        fuente: fuente,
        issuer: issDePrueba,
        audiencia: audDePrueba,
        ttlCache: 600,
        minEntreRefrescos: 60,
        maxTTLToken: maxTTLToken,
        reloj: { reloj.ahora }
    )
}

// MARK: - Tests

@Suite("Verificación de JWT (ADR-0014 §1)")
struct AuthTests {

    @Test("Un token ES256 válido da el MiembroId del claim `sub`")
    func tokenValidoDaElSub() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        let token = try await firmar(clave, sub: "abc-123")

        let miembro = try await verificador(fuente: fuente).miembro(deBearer: "Bearer \(token)")

        #expect(miembro == MiembroId("abc-123"))
    }

    @Test("Sin cabecera Authorization → sinCabecera (nunca se descarga la JWKS)")
    func sinCabecera() async throws {
        let fuente = FuenteFalsa(jwks(ClaveDePrueba(kid: "k1")))
        let v = verificador(fuente: fuente)

        await #expect(throws: ErrorAuth.sinCabecera) { try await v.miembro(deBearer: nil) }
        await #expect(throws: ErrorAuth.sinCabecera) { try await v.miembro(deBearer: "Basic dXNlcjpwYXNz") }
        #expect(await fuente.descargas == 0)
    }

    @Test("Confusión de algoritmos: HS256 firmado con el `kid` bueno se rechaza")
    func rechazaHS256() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        // El atacante firma con HMAC usando como secreto algo que conoce, y reusa el kid.
        let hmac = JWTKeyCollection()
        await hmac.add(hmac: "secreto-del-atacante", digestAlgorithm: .sha256, kid: .init(string: "k1"))
        let payload = ClaimsSupabase(
            iss: .init(value: issDePrueba), sub: .init(value: "intruso"),
            aud: .init(value: audDePrueba), iat: .init(value: Date()),
            exp: .init(value: Date().addingTimeInterval(300))
        )
        let token = try await hmac.sign(payload, kid: .init(string: "k1"))
        let v = verificador(fuente: fuente)

        await #expect(throws: ErrorAuth.tokenInvalido) { try await v.miembro(deBearer: "Bearer \(token)") }
    }

    @Test("`alg: none` se rechaza")
    func rechazaAlgNone() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        let valido = try await firmar(clave)
        let token = conCabecera(#"{"alg":"none","typ":"JWT","kid":"k1"}"#, payloadDe: valido)
        let v = verificador(fuente: fuente)

        await #expect(throws: ErrorAuth.tokenInvalido) { try await v.miembro(deBearer: "Bearer \(token)") }
    }

    @Test("Un token caducado se rechaza")
    func rechazaCaducado() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        let token = try await firmar(clave, expira: -1)
        let v = verificador(fuente: fuente)

        await #expect(throws: ErrorAuth.tokenInvalido) { try await v.miembro(deBearer: "Bearer \(token)") }
    }

    @Test("Con maxTTL configurado, un token de vida larga (exp-iat) se rechaza (ADR-0014 §1)")
    func rechazaTokenDeVidaLarga() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        // Token válido en firma/iss/aud/exp, pero con TTL de 1h (Supabase mal configurado).
        let token = try await firmar(clave, expira: 3600, ttl: 3600)
        let v = verificador(fuente: fuente, maxTTLToken: 300)

        await #expect(throws: ErrorAuth.tokenInvalido) { try await v.miembro(deBearer: "Bearer \(token)") }
    }

    @Test("Con maxTTL configurado, un token dentro del límite pasa")
    func aceptaTokenDentroDelMaxTTL() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        let token = try await firmar(clave, sub: "corto", expira: 240, ttl: 240)   // 4 min ≤ 5 min
        let v = verificador(fuente: fuente, maxTTLToken: 300)

        let miembro = try await v.miembro(deBearer: "Bearer \(token)")
        #expect(miembro == MiembroId("corto"))
    }

    @Test("Sin maxTTL (nil), no se aplica el límite: un token largo pasa")
    func sinMaxTTLNoSeAplica() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        let token = try await firmar(clave, sub: "largo", expira: 3600, ttl: 3600)
        let v = verificador(fuente: fuente)   // maxTTLToken nil por defecto

        let miembro = try await v.miembro(deBearer: "Bearer \(token)")
        #expect(miembro == MiembroId("largo"))
    }

    @Test("Otro emisor se rechaza (token de otro proyecto Supabase)")
    func rechazaOtroIssuer() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        let token = try await firmar(clave, iss: "https://otro.supabase.co/auth/v1")
        let v = verificador(fuente: fuente)

        await #expect(throws: ErrorAuth.tokenInvalido) { try await v.miembro(deBearer: "Bearer \(token)") }
    }

    @Test("Otra audiencia se rechaza")
    func rechazaOtraAudiencia() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        let token = try await firmar(clave, aud: "otro-servicio")
        let v = verificador(fuente: fuente)

        await #expect(throws: ErrorAuth.tokenInvalido) { try await v.miembro(deBearer: "Bearer \(token)") }
    }

    @Test("Firma con una clave que NO está en la JWKS → se rechaza")
    func rechazaClaveDesconocida() async throws {
        let buena = ClaveDePrueba(kid: "k1")
        let impostora = ClaveDePrueba(kid: "k1")     // mismo kid, otra clave
        let fuente = FuenteFalsa(jwks(buena))
        let token = try await firmar(impostora)
        let v = verificador(fuente: fuente)

        await #expect(throws: ErrorAuth.tokenInvalido) { try await v.miembro(deBearer: "Bearer \(token)") }
    }

    @Test("La JWKS se cachea: dos verificaciones dentro del TTL = una descarga")
    func cacheaDentroDelTTL() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        let reloj = RelojFalso()
        let v = verificador(fuente: fuente, reloj: reloj)
        let token = try await firmar(clave)

        _ = try await v.miembro(deBearer: "Bearer \(token)")
        reloj.avanzar(599)
        _ = try await v.miembro(deBearer: "Bearer \(token)")

        #expect(await fuente.descargas == 1)
    }

    @Test("Pasado el TTL, la JWKS se vuelve a descargar")
    func refrescaAlExpirarElTTL() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        let reloj = RelojFalso()
        let v = verificador(fuente: fuente, reloj: reloj)
        let token = try await firmar(clave)

        _ = try await v.miembro(deBearer: "Bearer \(token)")
        reloj.avanzar(601)
        _ = try await v.miembro(deBearer: "Bearer \(token)")

        #expect(await fuente.descargas == 2)
    }

    @Test("Rotación de clave: un `kid` desconocido fuerza un refresco y el token pasa")
    func refrescaAnteKidDesconocido() async throws {
        let vieja = ClaveDePrueba(kid: "k1")
        let nueva = ClaveDePrueba(kid: "k2")
        // Primera descarga: solo la vieja. Segunda: las dos (transición de rotación).
        let fuente = FuenteFalsa(jwks(vieja), jwks(vieja, nueva))
        let v = verificador(fuente: fuente)

        _ = try await v.miembro(deBearer: "Bearer \(try await firmar(vieja))")   // cachea la vieja
        let miembro = try await v.miembro(deBearer: "Bearer \(try await firmar(nueva, sub: "rotado"))")

        #expect(miembro == MiembroId("rotado"))
        #expect(await fuente.descargas == 2)
    }

    @Test("Un `kid` basura no martillea la JWKS: como mucho un refresco por ventana")
    func rateLimitDeRefrescos() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        let reloj = RelojFalso()
        let v = verificador(fuente: fuente, reloj: reloj)
        let basura = try await firmar(ClaveDePrueba(kid: "kid-inventado"))

        for _ in 0..<5 {
            await #expect(throws: ErrorAuth.tokenInvalido) { try await v.miembro(deBearer: "Bearer \(basura)") }
        }

        // 1 descarga inicial (caché vacía) + 1 refresco por kid desconocido. Ni una más.
        #expect(await fuente.descargas == 2)
    }

    @Test("Si la JWKS no se puede descargar → jwksNoDisponible (no se acepta el token)")
    func jwksCaida() async throws {
        let clave = ClaveDePrueba(kid: "k1")
        let fuente = FuenteFalsa(jwks(clave))
        await fuente.romper()
        let v = verificador(fuente: fuente)
        let token = try await firmar(clave)

        await #expect(throws: ErrorAuth.jwksNoDisponible) { try await v.miembro(deBearer: "Bearer \(token)") }
    }
}
