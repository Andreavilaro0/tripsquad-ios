// Adaptador Postgres de ChatRepositorio (M6, ADR-0021 borrador —
// docs/design/chat-scope-y-plan.md). Mapea contra la migración 0006
// (messages, id bigint identity). Mismo patrón que
// RepositorioItinerarioPostgres.swift: client.query con binds interpolados =
// seguros; sin transacción porque cada operación es una única sentencia (no
// hay lectura-antes-de-escribir que proteger de TOCTOU).
//
// Semántica de borrado/marcador REPLICADA literal de RepositorioEnMemoria
// (RepositorioEnMemoria.swift, extension ChatRepositorio):
//   - `borrar` sustituye el `body` en la propia fila por
//     `Mensaje.marcadorBorrado` en el momento del borrado (no al leer). Así
//     las lecturas (`mensajes`, `mensaje`) devuelven la columna `body` tal
//     cual está guardada, sin reinterpretar `deleted_at` — igual que el
//     diccionario en memoria, donde tras `borrar` el `Mensaje` guardado YA
//     tiene el marcador como body.
//   - `borrar` es idempotente: `deleted_at = coalesce(deleted_at, ahora)`
//     conserva la fecha del primer borrado (mismo criterio de tombstone que
//     `RepositorioViajePostgres.revocarInvitacion`). Reescribir `body` con el
//     mismo marcador en un segundo borrado es un no-op observable (el valor
//     ya era ese), así que una única sentencia sin guarda extra basta.
//   - `mensajes` filtra `id > since` (`since == nil` -> umbral 0, igual que
//     el repo en memoria) y ordena cronológicamente por `id` (cursor
//     monotónico); incluye los mensajes borrados (con su marcador) — el
//     soft-delete no los saca del hilo.

import Foundation
import Logging
import PostgresNIO
import TripSquadExpenses
import TripSquadDomain

extension RepositorioPostgres: ChatRepositorio {

    // MARK: - Enviar

    public func enviar(tripId: String, autor: MiembroId, body: String, ahora: Date) async throws -> Mensaje {
        let rows = try await client.query("""
            INSERT INTO messages (trip_id, member_id, body, created_at)
            VALUES (\(tripId), \(autor.raw), \(body), \(ahora))
            RETURNING id, created_at
            """, logger: logger)
        for try await (id, createdAt) in rows.decode((Int64, Date).self) {
            return Mensaje(id: id, tripId: tripId, autor: autor, body: body, deletedAt: nil, createdAt: createdAt)
        }
        // INSERT sin ON CONFLICT siempre devuelve una fila con RETURNING si
        // no lanza antes; esto es inalcanzable salvo fallo del driver.
        preconditionFailure("INSERT INTO messages RETURNING no devolvió fila")
    }

    // MARK: - Leer

    /// Cronológico (por `id`, cursor monotónico) y filtrado a `id > since`
    /// (`since == nil` = desde el principio) — plan §Contrato de dominio.
    /// `body` ya trae el marcador si el mensaje está borrado (lo escribió
    /// `borrar`); no se reinterpreta aquí `deleted_at`.
    public func mensajes(tripId: String, since: Int64?, limit: Int) async throws -> [Mensaje] {
        let umbral = since ?? 0
        let rows = try await client.query("""
            SELECT id, member_id, body, deleted_at, created_at
            FROM messages
            WHERE trip_id = \(tripId) AND id > \(umbral)
            ORDER BY id ASC
            LIMIT \(limit)
            """, logger: logger)
        var out: [Mensaje] = []
        for try await (id, memberId, body, deletedAt, createdAt)
            in rows.decode((Int64, String, String, Date?, Date).self) {
            out.append(Mensaje(
                id: id, tripId: tripId, autor: MiembroId(memberId), body: body,
                deletedAt: deletedAt, createdAt: createdAt))
        }
        return out
    }

    public func mensaje(id: Int64, en tripId: String) async throws -> Mensaje? {
        let rows = try await client.query("""
            SELECT id, member_id, body, deleted_at, created_at
            FROM messages
            WHERE id = \(id) AND trip_id = \(tripId)
            """, logger: logger)
        for try await (id, memberId, body, deletedAt, createdAt)
            in rows.decode((Int64, String, String, Date?, Date).self) {
            return Mensaje(
                id: id, tripId: tripId, autor: MiembroId(memberId), body: body,
                deletedAt: deletedAt, createdAt: createdAt)
        }
        return nil
    }

    // MARK: - Borrar

    /// Idempotente: `deleted_at = coalesce(deleted_at, ahora)` conserva la
    /// fecha del primer borrado (mismo criterio que
    /// `RepositorioViajePostgres.revocarInvitacion`); `body` se sustituye por
    /// el marcador en la propia fila, igual que `RepositorioEnMemoria`.
    public func borrar(id: Int64, en tripId: String, por actor: MiembroId, ahora: Date) async throws -> Bool {
        // Bead 48g (hallazgo Codex #58): la mutación va scopeada por membresía ACTUAL en el
        // MISMO statement (CTE) Y bloqueando la fila de `trip_members` con `FOR SHARE`. El lock
        // es lo clave: bajo READ COMMITTED un simple `EXISTS` comparte snapshot pero NO serializa
        // contra un `quitarMiembro` concurrente (su `UPDATE ... left_at` toma FOR UPDATE). Con
        // `FOR SHARE` las dos operaciones se serializan: si la revocación gana, este SELECT espera
        // y re-lee la fila ya con `left_at` puesto → `miembro` vacío → no borra y devuelve false;
        // si gana este statement, la revocación espera al commit. El UPDATE del WITH se ejecuta
        // siempre (Postgres corre los statements modificadores del WITH a completitud).
        let rows = try await client.query("""
            WITH miembro AS (
                SELECT 1 FROM trip_members
                WHERE trip_id = \(tripId) AND member_id = \(actor.raw) AND left_at IS NULL
                FOR SHARE
            ),
            borrado AS (
                UPDATE messages
                SET deleted_at = coalesce(deleted_at, \(ahora)), body = \(Mensaje.marcadorBorrado)
                WHERE id = \(id) AND trip_id = \(tripId) AND EXISTS(SELECT 1 FROM miembro)
                RETURNING 1
            )
            SELECT EXISTS(SELECT 1 FROM miembro) AS es_miembro
            """, logger: logger)
        for try await (esMiembro) in rows.decode(Bool.self) { return esMiembro }
        return false
    }
}
