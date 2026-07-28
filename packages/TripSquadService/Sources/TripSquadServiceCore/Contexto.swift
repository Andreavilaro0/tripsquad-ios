// El contexto de petición y el middleware de autenticación.
//
// La forma es deliberada: `ContextoTripSquad` lleva el miembro OPCIONAL (todavía
// nadie lo ha verificado), y `ContextoAutenticado` lo lleva NO-OPCIONAL. Un handler
// que recibe `ContextoAutenticado` tiene la garantía —del compilador, no de la
// disciplina— de que hubo un JWT válido. Una ruta nueva que se olvide del middleware
// no compila si pide el contexto autenticado, y falla cerrada (401) si lo pide sin él.

import Foundation
import Hummingbird
import TripSquadDomain
import TripSquadExpensesPostgres

/// Contexto base de todas las rutas. Las públicas (`/live`, `/health`) se quedan aquí.
public struct ContextoTripSquad: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// Lo rellena `AuthMiddleware`. `nil` = nadie lo ha autenticado (todavía).
    public var miembro: MiembroId?

    public init(source: Source) {
        self.coreContext = .init(source: source)
        self.miembro = nil
    }
}

/// Contexto de las rutas protegidas: el actor ya está verificado y es no-opcional.
public struct ContextoAutenticado: ChildRequestContext {
    public typealias ParentContext = ContextoTripSquad

    public var coreContext: CoreRequestContextStorage
    /// El miembro autenticado, sacado del claim `sub` del JWT.
    public let actor: MiembroId

    public init(context: ContextoTripSquad) throws {
        self.coreContext = context.coreContext
        // Defensa en profundidad: si alguien monta este contexto sin el middleware
        // delante, la ruta falla CERRADA en vez de servir sin autenticar.
        guard let miembro = context.miembro else { throw HTTPError(.unauthorized) }
        self.actor = miembro
    }
}

/// Verifica el `Authorization: Bearer` y deja el miembro en el contexto.
///
/// El mapeo del error a HTTP lo decide quien lo monta, porque **no es el mismo en la
/// API directa que en la cola** (ADR-0015 §2 / contrato §0).
public struct AuthMiddleware: RouterMiddleware {
    public typealias Context = ContextoTripSquad

    private let verificador: any VerificadorDeToken
    private let respuesta: @Sendable (ErrorAuth) -> Response

    public init(
        verificador: any VerificadorDeToken,
        respuesta: @escaping @Sendable (ErrorAuth) -> Response
    ) {
        self.verificador = verificador
        self.respuesta = respuesta
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        var context = context
        do {
            context.miembro = try await verificador.miembro(deBearer: request.autorizacion())
        } catch let error as ErrorAuth {
            return respuesta(error)
        }
        // Propaga el actor por `@TaskLocal` a TODA query por-usuario aguas abajo (repos
        // Postgres vía `enTransaccionConRolActual`), sin cambiar firmas. La RLS A+B
        // (ADR-0030) se evalúa así contra ESTE `sub` en cada lectura y escritura del
        // request, incluso bajo el rol de servicio sin BYPASSRLS.
        return try await ActorRLS.$actual.withValue(context.miembro) {
            try await next(request, context)
        }
    }
}

// MARK: - Mapeo del error de auth a HTTP

/// API directa: 401 si el token es del cliente, 503 si el que falla somos nosotros.
///
/// La distinción no es cosmética: `jwksNoDisponible` significa que no pudimos hablar
/// con Supabase, y devolver 401 ahí mandaría a la app a la pantalla de login por una
/// caída ajena al usuario.
@Sendable public func respuestaAuthAPI(_ error: ErrorAuth) -> Response {
    switch error {
    case .sinCabecera, .tokenInvalido:
        return errorJSON(.unauthorized, "not_authenticated")
    case .jwksNoDisponible:
        return errorJSON(.serviceUnavailable, "auth_unavailable")
    }
}

/// Cola de sync: el 401 es la ÚNICA 4xx admitida y el connector re-autentica con él
/// (contrato §0). Un fallo de JWKS es transitorio → 5xx, que el SDK reintenta; si
/// saliera como 401, el cliente pediría login por un problema nuestro.
@Sendable public func respuestaAuthCola(_ error: ErrorAuth) -> Response {
    switch error {
    case .sinCabecera, .tokenInvalido:
        return jsonCrudo(.unauthorized, #"{"error":"reauth"}"#)
    case .jwksNoDisponible:
        return jsonCrudo(.serviceUnavailable, #"{"error":"transient"}"#)
    }
}

func jsonCrudo(_ status: HTTPResponse.Status, _ body: String) -> Response {
    Response(status: status, headers: [.contentType: "application/json"],
             body: .init(byteBuffer: .init(string: body)))
}
