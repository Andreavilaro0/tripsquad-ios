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

// Supabase exige TLS (PGSSL=require); en local/CI va sin TLS.
let tls: PostgresClient.Configuration.TLS = (env["PGSSL"] == "require")
    ? .require(.makeClientConfiguration())
    : .disable

let pgConfig = PostgresClient.Configuration(
    host: env["PGHOST"] ?? "localhost",
    port: Int(env["PGPORT"] ?? "5432") ?? 5432,
    username: env["PGUSER"] ?? "postgres",
    password: env["PGPASSWORD"] ?? "postgres",
    database: env["PGDATABASE"] ?? "tripsquad",
    tls: tls
)
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
