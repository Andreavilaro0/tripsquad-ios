// Adaptador Postgres de FotoRepositorio (M7 Task 2, ADR-0022 borrador —
// docs/design/fotos-plan-stub.md). Mapea contra la migración 0007 (photos).
// Mismo patrón que RepositorioItinerarioPostgres.swift/RepositorioChatPostgres.swift:
// client.query con binds interpolados = seguros; sin transacción porque cada
// operación es una única sentencia (no hay lectura-antes-de-escribir que
// proteger de TOCTOU).
//
// Semántica REPLICADA literal de RepositorioEnMemoria (RepositorioEnMemoria.swift,
// extension FotoRepositorio):
//   - `marcarLista` es idempotente: marcar lista una foto ya `ready` sigue
//     devolviendo `true`. `false` solo si la foto no existe (o es de otro
//     tripId) — mismo criterio "sin fuga" que el resto del módulo. El UPDATE
//     condicional (`WHERE status = 'pending'`) solo afecta la transición real
//     pending -> ready; si 0 filas se relee el estado actual para distinguir
//     "ya estaba ready" (true) de "no existe en ese trip" (false).
//   - `listar` con `soloListas: true` filtra a `status = 'ready'` (las
//     `pending` no se muestran); orden `(created_at, id)` — mismo desempate
//     que el repo en memoria para ids creados en el mismo instante.
//   - `borrar` es un DELETE liso scoped por trip (sin tombstone, a diferencia
//     de mensajes/gastos: el metadato de una foto borrada no se conserva).

import Foundation
import Logging
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses

extension RepositorioPostgres: FotoRepositorio {

    // MARK: - Crear

    public func crearPendiente(_ f: Foto) async throws {
        // `f.uploadedBy` es el actor que sube -> enTransaccionConRol(actor:) explícito.
        try await client.enTransaccionConRol(actor: f.uploadedBy, logger: logger) { conn in
            _ = try await conn.query("""
                INSERT INTO photos
                    (id, trip_id, uploaded_by, storage_key, content_type, size_bytes, caption, status, created_at)
                VALUES
                    (\(f.id), \(f.tripId), \(f.uploadedBy.raw), \(f.storageKey), \(f.contentType), \(f.sizeBytes),
                     \(f.caption), \(f.status.rawValue), \(f.createdAt))
                """, logger: self.logger)
        }
    }

    // MARK: - Confirmar

    /// Idempotente (plan §Tareas, semántica replicada de `RepositorioEnMemoria`):
    /// el UPDATE condicional solo transiciona `pending -> ready`. Si 0 filas,
    /// se relee el estado actual: `ready` -> ya lo estaba (true); no existe en
    /// ese trip -> false.
    public func marcarLista(id: String, en tripId: String) async throws -> Bool {
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            let upd = try await conn.query("""
                UPDATE photos SET status = 'ready'
                WHERE id = \(id) AND trip_id = \(tripId) AND status = 'pending'
                RETURNING id
                """, logger: self.logger)
            for try await _ in upd.decode(String.self) { return true }

            let rows = try await conn.query(
                "SELECT status FROM photos WHERE id = \(id) AND trip_id = \(tripId)",
                logger: self.logger)
            for try await (status) in rows.decode(String.self) {
                return status == EstadoFoto.ready.rawValue
            }
            return false
        }
    }

    // MARK: - Leer

    public func foto(id: String, en tripId: String) async throws -> Foto? {
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            let rows = try await conn.query("""
                SELECT id, trip_id, uploaded_by, storage_key, content_type, size_bytes, caption, status, created_at
                FROM photos
                WHERE id = \(id) AND trip_id = \(tripId)
                """, logger: self.logger)
            for try await (rid, rtrip, uploadedBy, storageKey, contentType, sizeBytes, caption, status, createdAt)
                in rows.decode((String, String, String, String, String, Int64?, String?, String, Date).self) {
                return Foto(id: rid, tripId: rtrip, uploadedBy: MiembroId(uploadedBy), storageKey: storageKey,
                            contentType: contentType, sizeBytes: sizeBytes, caption: caption,
                            status: EstadoFoto(rawValue: status) ?? .pending, createdAt: createdAt)
            }
            return nil
        }
    }

    /// `soloListas: true` filtra a `status = 'ready'` (plan §Tareas: las
    /// `pending` no se muestran). Orden `(created_at, id)` — mismo desempate
    /// que `RepositorioEnMemoria.listar`.
    public func listar(_ tripId: String, soloListas: Bool, limit: Int) async throws -> [Foto] {
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            let rows: PostgresRowSequence
            if soloListas {
                rows = try await conn.query("""
                    SELECT id, trip_id, uploaded_by, storage_key, content_type, size_bytes, caption, status, created_at
                    FROM photos
                    WHERE trip_id = \(tripId) AND status = 'ready'
                    ORDER BY created_at, id
                    LIMIT \(limit)
                    """, logger: self.logger)
            } else {
                rows = try await conn.query("""
                    SELECT id, trip_id, uploaded_by, storage_key, content_type, size_bytes, caption, status, created_at
                    FROM photos
                    WHERE trip_id = \(tripId)
                    ORDER BY created_at, id
                    LIMIT \(limit)
                    """, logger: self.logger)
            }
            var out: [Foto] = []
            for try await (rid, rtrip, uploadedBy, storageKey, contentType, sizeBytes, caption, status, createdAt)
                in rows.decode((String, String, String, String, String, Int64?, String?, String, Date).self) {
                out.append(Foto(id: rid, tripId: rtrip, uploadedBy: MiembroId(uploadedBy), storageKey: storageKey,
                                contentType: contentType, sizeBytes: sizeBytes, caption: caption,
                                status: EstadoFoto(rawValue: status) ?? .pending, createdAt: createdAt))
            }
            return out
        }
    }

    // MARK: - Borrar

    /// DELETE liso scoped por trip: a diferencia de mensajes/gastos, el
    /// metadato de una foto borrada no se conserva como tombstone (plan
    /// §Tareas; mismo criterio que `RepositorioEnMemoria.borrar(fotoId:en:)`).
    public func borrar(fotoId: String, en tripId: String) async throws {
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            _ = try await conn.query(
                "DELETE FROM photos WHERE id = \(fotoId) AND trip_id = \(tripId)",
                logger: self.logger)
        }
    }

}
