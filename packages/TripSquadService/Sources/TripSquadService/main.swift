// Punto de entrada del servicio. Lee la config del ENTORNO (12-factor / Render):
// DATABASE_URL o PG* + PORT. Monta el PostgresClient, lo corre en un task group
// junto con la app HTTP.

import Foundation
import Hummingbird
import Logging
import NIOSSL
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses
import TripSquadExpensesPostgres
import TripSquadServiceCore

let env = ProcessInfo.processInfo.environment
let port = Int(env["PORT"] ?? "8080") ?? 8080
let host = env["HOST"] ?? "0.0.0.0"                 // Render enruta al 0.0.0.0:$PORT
let logger = Logger(label: "tripsquad")

/// Config de Postgres desde el entorno. Prioriza `DATABASE_URL` (la cadena única de
/// Supabase: `postgresql://user:pass@host:port/db`), y si no está, cae a las
/// variables `PG*` sueltas (hallazgo P2 de Codex). TLS se exige si la URL pide
/// sslmode=require o si `PGSSL=require`.
func configPostgres(_ env: [String: String]) -> PostgresClient.Configuration {
    if let raw = env["DATABASE_URL"], let c = URLComponents(string: raw), let host = c.host {
        let sslRequerido = c.queryItems?.contains { $0.name == "sslmode" && $0.value == "require" } ?? false
        let tls: PostgresClient.Configuration.TLS = sslRequerido ? .require(.makeClientConfiguration()) : .disable
        return .init(
            host: host,
            port: c.port ?? 5432,
            username: c.user ?? "postgres",
            password: c.password ?? "",
            database: String(c.path.dropFirst()),   // quita la barra inicial
            tls: tls
        )
    }
    let tls: PostgresClient.Configuration.TLS = (env["PGSSL"] == "require")
        ? .require(.makeClientConfiguration()) : .disable
    return .init(
        host: env["PGHOST"] ?? "localhost",
        port: Int(env["PGPORT"] ?? "5432") ?? 5432,
        username: env["PGUSER"] ?? "postgres",
        password: env["PGPASSWORD"] ?? "postgres",
        database: env["PGDATABASE"] ?? "tripsquad",
        tls: tls
    )
}

let pgConfig = configPostgres(env)
let client = PostgresClient(configuration: pgConfig)

let repo = RepositorioPostgres(client: client, logger: logger)
let deps = Dependencias(
    casos: CasosDeUsoGastos(repo: repo, membresia: repo),
    repo: repo,
    pingBD: {
        do { _ = try await client.query("SELECT 1", logger: logger); return true }
        catch { return false }
    }
)

let app = construirApp(deps, host: host, port: port)

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await client.run() }              // el cliente Postgres corre en background
    group.addTask { try await app.runService() }      // la app HTTP
    try await group.next()
    group.cancelAll()
}
