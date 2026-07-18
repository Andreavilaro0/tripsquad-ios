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
    public let repo: GastoRepositorio
    public let pingBD: @Sendable () async -> Bool   // para /health

    public init(casos: CasosDeUsoGastos, repo: GastoRepositorio, pingBD: @escaping @Sendable () async -> Bool) {
        self.casos = casos
        self.repo = repo
        self.pingBD = pingBD
    }
}

/// Construye el router con todas las rutas montadas.
public func construirRouter(_ deps: Dependencias) -> Router<BasicRequestContext> {
    let router = Router()
    router.add(middleware: LogRequestsMiddleware(.info))

    montarSalud(router, deps)
    montarGastos(router, deps)
    montarSyncUpload(router, deps)

    return router
}

/// Arranca la app HTTP escuchando en `host:port`.
public func construirApp(_ deps: Dependencias, host: String, port: Int) -> some ApplicationProtocol {
    Application(
        router: construirRouter(deps),
        configuration: .init(address: .hostname(host, port: port), serverName: "TripSquad")
    )
}
