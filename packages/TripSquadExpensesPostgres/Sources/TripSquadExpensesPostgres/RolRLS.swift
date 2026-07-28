// Mecanismo de RLS bajo el rol de servicio (ADR-0030, bead 5n3). Único seam por el que
// debe pasar TODO camino de datos por-usuario: abre una transacción y fija el contexto
// RLS (Opción A) antes de ejecutar las queries del cuerpo, de modo que las policies
// `private.*` (Opción B) se evalúen contra ESTE usuario.
//
// Por qué un helper único: el doc de investigación 5n3 avisa de que si un camino olvida
// el `SET LOCAL role` + claims, la RLS no filtra por usuario y hay FUGA. Concentrarlo aquí
// lo hace difícil de olvidar (y fácil de auditar: un solo sitio que fija el contexto).

import Foundation
import Logging
import PostgresNIO
import TripSquadDomain

/// Actor RLS propagado por la petición sin tocar firmas (bead RLS-enrutado). El
/// `AuthMiddleware` lo fija con `ActorRLS.$actual.withValue(actor) { next(...) }` tras
/// verificar el JWT, de modo que TODA query por-usuario aguas abajo (repos Postgres)
/// hereda el actor por `@TaskLocal` y puede abrir su transacción-con-rol sin recibir el
/// `MiembroId` como parámetro explícito. Es la fuente de verdad de "en nombre de quién"
/// se ejecuta la query — leída SOLO por `enTransaccionConRolActual`.
///
/// `nil` = no hay contexto de usuario (petición pública, cron, o un camino que se saltó
/// el middleware). Las queries por-usuario tratan ese `nil` como error FAIL-CLOSED (no
/// corren sin filtro); las operaciones de sistema (sin actor) NO usan este task-local:
/// van por funciones `security definer` (migración 0015).
public enum ActorRLS {
    @TaskLocal public static var actual: MiembroId?
}

/// Error del enrutado RLS por task-local.
public enum ErrorRLS: Error, Equatable {
    /// Una query por-usuario intentó abrir su transacción-con-rol sin `ActorRLS.actual`
    /// fijado. Fail-closed: se lanza en vez de ejecutar sin el filtro RLS (que, bajo el
    /// rol de servicio sin BYPASSRLS, no devolvería/afectaría ninguna fila silenciosamente
    /// y rompería la idempotencia y las lecturas). Nunca debe pasar en producción: el
    /// `AuthMiddleware` fija el actor para toda ruta autenticada.
    case sinContextoDeUsuario
}

extension PostgresClient {

    /// Igual que `enTransaccionConRol(actor:)` pero tomando el actor del `@TaskLocal`
    /// `ActorRLS.actual` (lo fija el `AuthMiddleware`). Es el seam por el que pasan las
    /// lecturas Y escrituras por-usuario de los repos Postgres sin arrastrar el `MiembroId`
    /// por sus firmas.
    ///
    /// FAIL-CLOSED: si `ActorRLS.actual` es `nil` LANZA `ErrorRLS.sinContextoDeUsuario` —
    /// jamás ejecuta el cuerpo sin contexto RLS. Las operaciones de sistema (sin usuario:
    /// caducidad de settlements, lookup de código de invitación de un no-miembro) NO llaman
    /// aquí: usan funciones `security definer` (migración 0015).
    public func enTransaccionConRolActual<Result: Sendable>(
        logger: Logger,
        _ cuerpo: (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        guard let actor = ActorRLS.actual else { throw ErrorRLS.sinContextoDeUsuario }
        return try await enTransaccionConRol(actor: actor, logger: logger, cuerpo)
    }

    /// Abre una transacción y fija el contexto RLS por-usuario (mecanismo A+B, ADR-0030)
    /// antes de correr `cuerpo`:
    ///   - `set_config('role', 'authenticated', true)` ≡ `SET LOCAL ROLE authenticated`
    ///     (Postgres trata `role` como GUC especial que conmuta el rol activo, igual que
    ///     hace PostgREST antes de la query del usuario);
    ///   - `set_config('request.jwt.claims', {"sub": actor}, true)` para que `private.uid()`
    ///     (claim `sub`) identifique al actor en las policies.
    /// El `true` es transaction-local (`SET LOCAL`): se revierte al COMMIT/ROLLBACK, seguro
    /// con pooling. El rol de conexión de la app debe poder `SET ROLE authenticated` y NO
    /// tener `BYPASSRLS` (gate de entorno, ADR-0030 §Consecuencias).
    public func enTransaccionConRol<Result: Sendable>(
        actor: MiembroId,
        logger: Logger,
        _ cuerpo: (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        try await withTransaction(logger: logger) { conn in
            try await Self.fijarContextoRLS(conn, actor: actor, logger: logger)
            return try await cuerpo(conn)
        }
    }

    /// Fija rol + claims en una conexión que YA está en transacción (para reusar desde un
    /// `withTransaction` existente sin anidar). Idempotente dentro de la misma transacción.
    static func fijarContextoRLS(_ conn: PostgresConnection, actor: MiembroId, logger: Logger) async throws {
        // set_config('role', ...): value literal, sin datos de usuario -> sin riesgo de inyección.
        _ = try await conn.query("SELECT set_config('role', 'authenticated', true)", logger: logger)
        // Claims: JSON con sub = actor. Se serializa con JSONEncoder para escapar de forma
        // segura cualquier carácter del id, y se pasa como bind (PostgresNIO parametriza la
        // interpolación) -> doblemente a salvo de inyección.
        let claims = String(decoding: try JSONEncoder().encode(ClaimsRLS(sub: actor.raw)), as: UTF8.self)
        _ = try await conn.query("SELECT set_config('request.jwt.claims', \(claims), true)", logger: logger)
    }
}

/// Forma mínima de `request.jwt.claims` que consume `private.uid()` (claim `sub`). Se
/// incluye `role` por paridad con lo que emite PostgREST, aunque el rol ya se fija aparte.
private struct ClaimsRLS: Encodable {
    let sub: String
    let role: String = "authenticated"
}
