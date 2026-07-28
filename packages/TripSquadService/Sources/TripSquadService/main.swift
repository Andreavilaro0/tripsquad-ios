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

/// Decide si la conexión a Postgres va cifrada. **Falla CERRADO** (P1 de la revisión
/// integrada): antes, un host REMOTO sin `sslmode=require` iba en TEXTO PLANO en
/// silencio — credenciales y todos los datos del viaje viajando sin cifrar a Supabase.
/// Ahora el default es TLS y solo se baja a plano en tres casos EXPLÍCITOS:
///   - `sslmode=disable` (el usuario lo pide a mano),
///   - `PG_ALLOW_PLAINTEXT=1` (escape para desarrollo),
///   - host local (localhost/127.0.0.1/::1): el Postgres de dev/CI no tiene TLS.
/// Cualquier otra forma de `sslmode` (require/verify-ca/verify-full/prefer/allow) es
/// "sí, cifra" — antes solo se reconocía `require`, así que `verify-full` caía a plano.
func postgresTLS(host: String, sslmode: String?, _ env: [String: String]) -> PostgresClient.Configuration.TLS {
    let plano = PostgresClient.Configuration.TLS.disable
    let cifrado = PostgresClient.Configuration.TLS.require(.makeClientConfiguration())
    if env["PG_ALLOW_PLAINTEXT"] == "1" { return plano }
    if let m = sslmode?.lowercased() {
        if m == "disable" { return plano }
        if ["require", "verify-ca", "verify-full", "prefer", "allow"].contains(m) { return cifrado }
    }
    let locales: Set<String> = ["localhost", "127.0.0.1", "::1"]
    return locales.contains(host) ? plano : cifrado   // remoto sin pistas -> cifra (falla cerrado)
}

/// Config de Postgres desde el entorno. Prioriza `DATABASE_URL` (la cadena única de
/// Supabase: `postgresql://user:pass@host:port/db`), y si no está, cae a las
/// variables `PG*` sueltas (hallazgo P2 de Codex).
func configPostgres(_ env: [String: String]) -> PostgresClient.Configuration {
    if let raw = env["DATABASE_URL"], let c = URLComponents(string: raw), let host = c.host {
        let sslmode = c.queryItems?.first { $0.name == "sslmode" }?.value
        return .init(
            host: host,
            port: c.port ?? 5432,
            username: c.user ?? "postgres",
            password: c.password ?? "",
            database: String(c.path.dropFirst()),   // quita la barra inicial
            tls: postgresTLS(host: host, sslmode: sslmode, env)
        )
    }
    let host = env["PGHOST"] ?? "localhost"
    // `PGSSL=require` se mantiene por compatibilidad; el resto lo decide postgresTLS.
    let sslmode = env["PGSSL"]
    return .init(
        host: host,
        port: Int(env["PGPORT"] ?? "5432") ?? 5432,
        username: env["PGUSER"] ?? "postgres",
        password: env["PGPASSWORD"] ?? "postgres",
        database: env["PGDATABASE"] ?? "tripsquad",
        tls: postgresTLS(host: host, sslmode: sslmode, env)
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

// estructurador: FAKE por defecto. El adaptador real DeepSeek (dy5 Task 5) solo se
// activa si `DEEPSEEK_API_KEY` está en el entorno.
// GATED: activar requiere OK de Andrea + tope de presupuesto.
let estructurador: EstructuradorConfirmacion
if let deepSeekKey = env["DEEPSEEK_API_KEY"], !deepSeekKey.isEmpty {
    logger.info("confirmaciones: estructurador = DeepSeek (real)")
    // Modelo configurable por env; por defecto `deepseek-v4-flash` (el barato, y el que
    // expone la cuenta — `deepseek-chat` no aparece en su lista de modelos).
    estructurador = EstructuradorConfirmacionDeepSeek(
        apiKey: deepSeekKey,
        modelo: env["DEEPSEEK_MODEL"] ?? "deepseek-v4-flash",
        httpClient: ClienteHTTPDeepSeekReal(cliente: http))
} else {
    logger.info("confirmaciones: estructurador = fake (DEEPSEEK_API_KEY no está en el entorno)")
    estructurador = EstructuradorConfirmacionFake(datos: DatosConfirmacion(
        tipo: .vuelo, fechaISO: nil, numeroConfirmacion: nil, proveedor: nil))
}

// storage de fotos: STUB por defecto. El adaptador real R2 (bead 7n3, ADR-0022)
// solo se activa si TODAS las credenciales R2 están en el entorno.
// GATED: activar requiere que Andrea cree el bucket + las API tokens de R2.
let fotoStorage: FotoStorage
if let r2Account = env["R2_ACCOUNT_ID"], !r2Account.isEmpty,
   let r2Access = env["R2_ACCESS_KEY"], !r2Access.isEmpty,
   let r2Secret = env["R2_SECRET"], !r2Secret.isEmpty,
   let r2Bucket = env["R2_BUCKET"], !r2Bucket.isEmpty {
    logger.info("fotos: storage = R2 (real), bucket=\(r2Bucket)")
    fotoStorage = FotoStorageR2(
        accountId: r2Account, accessKey: r2Access, secretKey: r2Secret, bucket: r2Bucket,
        region: env["R2_REGION"] ?? "auto",
        httpCliente: ClienteHTTPR2Real(cliente: http))
} else {
    logger.info("fotos: storage = stub (credenciales R2 no están en el entorno)")
    fotoStorage = FotoStorageStub()
}

// asistente Brújula: STUB por defecto (cero gasto, cero red). El adaptador real
// DeepSeek (bead 3dk) solo se activa si `DEEPSEEK_ASISTENTE_API_KEY` está en el
// entorno — key SEPARADA de la del estructurador para que activar una no encienda
// la otra. GATED: activar requiere OK de Andrea + tope de presupuesto.
let asistente: AsistenteIA
if let asistenteKey = env["DEEPSEEK_ASISTENTE_API_KEY"], !asistenteKey.isEmpty {
    let topeDiario = env["DEEPSEEK_BRUJULA_TOPE_DIARIO"].flatMap(Int.init) ?? AsistenteDeepSeek.topeDiarioPorDefecto
    logger.info("brújula: asistente = DeepSeek (real), tope=\(topeDiario)/usuario/viaje/día")
    asistente = AsistenteDeepSeek(
        apiKey: asistenteKey,
        modelo: env["DEEPSEEK_MODEL"] ?? "deepseek-v4-flash",
        topeDiario: topeDiario,
        httpClient: ClienteHTTPDeepSeekReal(cliente: http))
} else {
    logger.info("brújula: asistente = stub (DEEPSEEK_ASISTENTE_API_KEY no está en el entorno)")
    asistente = AsistenteStub()
}

let deps = Dependencias(
    casos: CasosDeUsoGastos(repo: repo, membresia: repo),
    casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
    casosViaje: CasosDeUsoViaje(repo: repo),
    casosVotacion: CasosDeUsoVotacion(repo: repo, membresia: repo, viajes: repo),
    casosItinerario: CasosDeUsoItinerario(repo: repo, membresia: repo, viajes: repo),
    casosReserva: CasosDeUsoReserva(repo: repo, itinerario: repo, membresia: repo, viajes: repo,
        estructurador: estructurador),
    casosChat: CasosDeUsoChat(repo: repo, membresia: repo),
    casosFoto: CasosDeUsoFoto(repo: repo, membresia: repo, viajes: repo, storage: fotoStorage),
    casosBrujula: CasosDeUsoBrujula(repo: repo, membresia: repo, settlements: repo, asistente: asistente),
    repo: repo,
    pingBD: {
        do { _ = try await client.query("SELECT 1", logger: logger); return true }
        catch { return false }
    },
    verificador: verificador,
    idempotencia: repo   // durable en Postgres (bead 379); el default en memoria es solo para tests
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
