// Punto de entrada del servicio. Lee la config del ENTORNO (12-factor / Render):
// DATABASE_URL o PG* + PORT. Monta el PostgresClient, lo corre en un task group
// junto con la app HTTP.

import AsyncHTTPClient
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

/// Config de autenticación (ADR-0014 §1). **Falla al arrancar** si falta: un servicio
/// que arranca sin saber contra qué JWKS validar solo puede hacer una cosa mal.
func exigir(_ clave: String) -> String {
    guard let v = env[clave], !v.isEmpty else {
        FileHandle.standardError.write(Data("FATAL: falta la variable de entorno \(clave)\n".utf8))
        exit(1)
    }
    return v
}

let supabaseURL = exigir("SUPABASE_URL").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
let jwksURL = env["SUPABASE_JWKS_URL"] ?? "\(supabaseURL)/auth/v1/.well-known/jwks.json"
let jwtIssuer = env["JWT_ISS"] ?? "\(supabaseURL)/auth/v1"
let jwtAudiencia = env["JWT_AUD"] ?? "authenticated"

// Edad máxima del token (ADR-0014 §1, defensa en profundidad). OFF por defecto: el
// TTL por defecto de Supabase son 3600 s, así que activarlo por debajo rechazaría
// tokens legítimos. Para honrar el ADR (≤5 min): configura el access-token TTL de
// Supabase a 5 min y pon JWT_MAX_TTL_SECONDS=330 (5 min + margen de reloj).
let maxTTLToken = env["JWT_MAX_TTL_SECONDS"].flatMap { TimeInterval($0) }

let http = HTTPClient(eventLoopGroupProvider: .singleton)
let verificador = VerificadorSupabase(
    fuente: FuenteJWKSHTTP(cliente: http, url: jwksURL),
    issuer: jwtIssuer,
    audiencia: jwtAudiencia,
    maxTTLToken: maxTTLToken
)
logger.info("auth: JWKS en \(jwksURL), iss=\(jwtIssuer), aud=\(jwtAudiencia), maxTTL=\(maxTTLToken.map { "\($0)s" } ?? "off")")

let pgConfig = configPostgres(env)
let client = PostgresClient(configuration: pgConfig)

let repo = RepositorioPostgres(client: client, logger: logger)
let deps = Dependencias(
    casos: CasosDeUsoGastos(repo: repo, membresia: repo),
    casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
    casosViaje: CasosDeUsoViaje(repo: repo),
    repo: repo,
    pingBD: {
        do { _ = try await client.query("SELECT 1", logger: logger); return true }
        catch { return false }
    },
    verificador: verificador
)

let app = construirApp(deps, host: host, port: port)

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await client.run() }              // el cliente Postgres corre en background
    group.addTask { try await app.runService() }      // la app HTTP
    try await group.next()
    group.cancelAll()
}

// `http` es global y vive toda la vida del proceso; el task group solo retorna al
// apagar el servidor, justo antes de que el proceso termine. No hace falta un
// shutdown explícito (nunca hay deinit en caliente que dispare el aviso de HTTPClient).
