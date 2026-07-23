// Construcción del router de TripSquad. Cablea los casos de uso de Expenses
// (dominio + adaptador) con los endpoints HTTP.

import Foundation
import Hummingbird
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses

/// Dependencias que el servicio inyecta en las rutas. Permite tests con adaptador
/// en memoria y producción con Postgres, sin que las rutas conozcan la diferencia.
public struct Dependencias: Sendable {
    public let casos: CasosDeUsoGastos
    public let casosSettle: CasosDeUsoSettle
    public let casosViaje: CasosDeUsoViaje         // onboarding: viajes/invites/miembros (ADR-0018)
    public let repo: GastoRepositorio
    public let pingBD: @Sendable () async -> Bool   // para /health
    public let verificador: any VerificadorDeToken  // Bearer JWT (ADR-0014 §1)
    /// Reloj inyectable (tests deterministas). Default = reloj real; no rompe
    /// los call sites existentes que no lo pasan explícitamente.
    public let ahora: @Sendable () -> Date

    public init(
        casos: CasosDeUsoGastos,
        casosSettle: CasosDeUsoSettle,
        casosViaje: CasosDeUsoViaje,
        repo: GastoRepositorio,
        pingBD: @escaping @Sendable () async -> Bool,
        verificador: any VerificadorDeToken,
        ahora: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.casos = casos
        self.casosSettle = casosSettle
        self.casosViaje = casosViaje
        self.repo = repo
        self.pingBD = pingBD
        self.verificador = verificador
        self.ahora = ahora
    }
}

/// Construye el router con todas las rutas montadas.
///
/// Reparto de contextos: `/live` y `/health` son públicos y se quedan en el contexto
/// base; todo lo demás pasa por `AuthMiddleware` y sube al contexto autenticado, donde
/// el actor ya es no-opcional. Los dos grupos protegidos existen porque el 401 NO se
/// escribe igual en la API directa que en la cola (contrato §0).
public func construirRouter(_ deps: Dependencias) -> Router<ContextoTripSquad> {
    let router = Router(context: ContextoTripSquad.self)
    router.add(middleware: LogRequestsMiddleware(.info))

    montarSalud(router, deps)

    montarGastos(
        router.group()
            .add(middleware: AuthMiddleware(verificador: deps.verificador, respuesta: respuestaAuthAPI))
            .group(context: ContextoAutenticado.self),
        deps
    )

    montarSettle(
        router.group()
            .add(middleware: AuthMiddleware(verificador: deps.verificador, respuesta: respuestaAuthAPI))
            .group(context: ContextoAutenticado.self),
        deps
    )

    montarViajes(
        router.group()
            .add(middleware: AuthMiddleware(verificador: deps.verificador, respuesta: respuestaAuthAPI))
            .group(context: ContextoAutenticado.self),
        deps
    )

    montarSyncUpload(
        router.group()
            .add(middleware: AuthMiddleware(verificador: deps.verificador, respuesta: respuestaAuthCola))
            .group(context: ContextoAutenticado.self),
        deps
    )

    return router
}

/// Arranca la app HTTP escuchando en `host:port`.
public func construirApp(_ deps: Dependencias, host: String, port: Int) -> some ApplicationProtocol {
    Application(
        router: construirRouter(deps),
        configuration: .init(address: .hostname(host, port: port), serverName: "TripSquad")
    )
}
