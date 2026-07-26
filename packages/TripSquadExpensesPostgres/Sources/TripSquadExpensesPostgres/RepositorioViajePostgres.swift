// Adaptador Postgres del repositorio de viajes/miembros/invitaciones (ADR-0018).
// Mapea `ViajeRepositorio` (TripSquadExpenses) contra el esquema de db/migrations
// 0001 (trips, trip_members) + 0003 (name/base_currency/created_by/created_at,
// role/joined_at, trip_invites). Mismo patrón que RepositorioPostgres.swift:
// client.query con binds interpolados = seguros, withTransaction para las
// operaciones multi-paso (crearViaje, unirsePorCodigo).

import Foundation
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses

extension RepositorioPostgres: ViajeRepositorio {

    // MARK: - Crear / leer viajes

    /// Crea el viaje y mete al creador como `owner` en la misma transacción: un
    /// viaje sin dueño no es un estado válido (mismo principio que el caso de
    /// uso, `CasosDeUsoViaje.crear`). `currency_reference` (columna de 0001, usada
    /// por `expenses` para fijar la divisa de referencia) se iguala a
    /// `base_currency`: un viaje, una sola divisa de referencia.
    public func crearViaje(id: String, name: String, baseCurrency: String, creador: MiembroId, ahora: Date) async throws -> Viaje {
        try await client.withTransaction(logger: logger) { conn in
            _ = try await conn.query("""
                INSERT INTO trips (id, currency_reference, name, base_currency, created_by, created_at)
                VALUES (\(id), \(baseCurrency), \(name), \(baseCurrency), \(creador.raw), \(ahora))
                """, logger: self.logger)
            _ = try await conn.query("""
                INSERT INTO trip_members (trip_id, member_id, role, joined_at)
                VALUES (\(id), \(creador.raw), 'owner', \(ahora))
                """, logger: self.logger)
            return Viaje(id: id, name: name, baseCurrency: baseCurrency, createdBy: creador, closedAt: nil)
        }
    }

    public func viaje(id: String) async throws -> Viaje? {
        let rows = try await client.query(
            "SELECT name, base_currency, created_by, closed_at FROM trips WHERE id = \(id)",
            logger: logger)
        for try await (name, baseCurrency, createdBy, closedAt) in rows.decode((String, String, String, Date?).self) {
            return Viaje(id: id, name: name, baseCurrency: baseCurrency, createdBy: MiembroId(createdBy), closedAt: closedAt)
        }
        return nil
    }

    /// `ORDER BY t.id` (antes `t.created_at`): el adaptador en memoria ordenaba por
    /// `id` y este por `created_at` — dos órdenes distintos para el mismo listado, y
    /// además `created_at` no es único (dos viajes creados en el mismo tick empatan sin
    /// desempate). Se unifica al `id` porque `Viaje` (dominio) NO lleva `createdAt`:
    /// ordenar por fecha aquí sería un criterio que memoria no puede reproducir.
    /// `limit` llega ya clampado de `CasosDeUsoViaje.misViajes`.
    public func viajesDe(_ actor: MiembroId, limit: Int) async throws -> [Viaje] {
        let rows = try await client.query("""
            SELECT t.id, t.name, t.base_currency, t.created_by, t.closed_at
            FROM trips t
            JOIN trip_members m ON m.trip_id = t.id
            WHERE m.member_id = \(actor.raw) AND m.left_at IS NULL
            ORDER BY t.id
            LIMIT \(limit)
            """, logger: logger)
        var out: [Viaje] = []
        for try await (id, name, baseCurrency, createdBy, closedAt) in rows.decode((String, String, String, String, Date?).self) {
            out.append(Viaje(id: id, name: name, baseCurrency: baseCurrency, createdBy: MiembroId(createdBy), closedAt: closedAt))
        }
        return out
    }

    // MARK: - Miembros / roles

    /// `ORDER BY member_id`: sin él Postgres devolvía el orden físico del heap
    /// (cambia con cada UPDATE de `left_at`) mientras memoria sí ordenaba — la lista de
    /// miembros del mismo viaje salía distinta según el adaptador. Sin `LIMIT`: el
    /// tamaño ya está acotado por el tope de 50 miembros (ADR-0018 §8).
    public func miembros(de tripId: String) async throws -> [(MiembroId, RolMiembro)] {
        let rows = try await client.query(
            "SELECT member_id, role FROM trip_members WHERE trip_id = \(tripId) AND left_at IS NULL ORDER BY member_id",
            logger: logger)
        var out: [(MiembroId, RolMiembro)] = []
        for try await (memberId, role) in rows.decode((String, String).self) {
            guard let rol = RolMiembro(rawValue: role) else { continue }
            out.append((MiembroId(memberId), rol))
        }
        return out
    }

    /// `nil` = no es miembro activo — ÚNICA fuente de verdad de autorización de
    /// este dominio (ver doc de `ViajeRepositorio`), indistinguible desde fuera
    /// de "el viaje no existe".
    public func rol(de actor: MiembroId, en tripId: String) async throws -> RolMiembro? {
        let rows = try await client.query(
            "SELECT role FROM trip_members WHERE trip_id = \(tripId) AND member_id = \(actor.raw) AND left_at IS NULL",
            logger: logger)
        for try await (role) in rows.decode(String.self) {
            return RolMiembro(rawValue: role)
        }
        return nil
    }

    // MARK: - Invitaciones

    public func crearInvitacion(tripId: String, por: MiembroId, code: String, expiresAt: Date) async throws -> Invitacion {
        _ = try await client.query("""
            INSERT INTO trip_invites (code, trip_id, created_by, expires_at)
            VALUES (\(code), \(tripId), \(por.raw), \(expiresAt))
            """, logger: logger)
        return Invitacion(code: code, tripId: tripId, createdBy: por, expiresAt: expiresAt, revokedAt: nil)
    }

    public func revocarInvitacion(code: String, en tripId: String, ahora: Date) async throws -> Bool {
        // Idempotente (igual que RepositorioEnMemoria, hallazgo Codex P3): revoca si no lo
        // estaba (coalesce conserva el revoked_at original), y devuelve true si la
        // invitación existe en ESE viaje — ya revocada o recién revocada. false solo si el
        // code no existe o es de otro viaje.
        let rows = try await client.query("""
            UPDATE trip_invites SET revoked_at = coalesce(revoked_at, \(ahora))
            WHERE code = \(code) AND trip_id = \(tripId)
            RETURNING code
            """, logger: logger)
        for try await _ in rows { return true }
        return false
    }

    // MARK: - Unirse

    /// Todo en una transacción (spec del brief): código válido/vivo/no-revocado,
    /// viaje abierto, membresía previa y tope se comprueban contra la misma foto
    /// consistente antes de mutar `trip_members` — evita carreras entre el check
    /// y la escritura.
    public func unirsePorCodigo(code: String, actor: MiembroId, ahora: Date, tope: Int) async throws -> ResultadoUnirse {
        try await client.withTransaction(logger: logger) { conn in
            let inviteRows = try await conn.query(
                "SELECT trip_id, expires_at, revoked_at FROM trip_invites WHERE code = \(code)",
                logger: self.logger)
            var tripId: String?
            var expiresAt: Date?
            var revokedAt: Date?
            for try await (t, e, r) in inviteRows.decode((String, Date, Date?).self) {
                tripId = t
                expiresAt = e
                revokedAt = r
            }
            guard let tripId, let expiresAt else { return .codigoInvalido }
            if revokedAt != nil { return .revocado }
            if expiresAt < ahora { return .caducado }

            // FOR UPDATE bloquea la fila del viaje durante toda la transacción: los joins
            // concurrentes al MISMO viaje se serializan aquí, así el conteo del tope y el
            // insert son atómicos (Codex/Gemini P2: sin esto, dos joins leen activos<tope y
            // ambos entran, superando el límite). Si el viaje no existe (invitación colgada,
            // Codex P2), el code es inválido.
            let tripRows = try await conn.query(
                "SELECT closed_at FROM trips WHERE id = \(tripId) FOR UPDATE", logger: self.logger)
            var tripExiste = false
            for try await (closedAt) in tripRows.decode(Date?.self) {
                tripExiste = true
                if closedAt != nil { return .viajeCerrado }
            }
            guard tripExiste else { return .codigoInvalido }

            let activoRows = try await conn.query("""
                SELECT 1 FROM trip_members
                WHERE trip_id = \(tripId) AND member_id = \(actor.raw) AND left_at IS NULL
                """, logger: self.logger)
            for try await _ in activoRows { return .yaMiembro }

            let countRows = try await conn.query(
                "SELECT count(*) FROM trip_members WHERE trip_id = \(tripId) AND left_at IS NULL",
                logger: self.logger)
            var activos: Int64 = 0
            for try await (c) in countRows.decode(Int64.self) { activos = c }
            if activos >= tope { return .lleno }

            // Fila previa (miembro que salió: left_at != nil) -> reactivar en vez de
            // insertar, la PK es (trip_id, member_id).
            let existeFila = try await conn.query(
                "SELECT 1 FROM trip_members WHERE trip_id = \(tripId) AND member_id = \(actor.raw)",
                logger: self.logger)
            var reingresa = false
            for try await _ in existeFila { reingresa = true }

            if reingresa {
                _ = try await conn.query("""
                    UPDATE trip_members SET left_at = NULL, joined_at = \(ahora)
                    WHERE trip_id = \(tripId) AND member_id = \(actor.raw)
                    """, logger: self.logger)
            } else {
                _ = try await conn.query("""
                    INSERT INTO trip_members (trip_id, member_id, role, joined_at)
                    VALUES (\(tripId), \(actor.raw), 'member', \(ahora))
                    """, logger: self.logger)
            }
            return .unido
        }
    }

    // MARK: - Salir / cerrar

    /// Marca la salida Y revoca, EN LA MISMA TRANSACCIÓN, las invitaciones que ese
    /// miembro emitió (ADR-0014 §2 — P1 de la revisión integrada). Sin esto, un
    /// expulsado seguía teniendo su `code` vivo hasta 7 días y `unirsePorCodigo` lo
    /// reactivaba (`left_at = NULL`): reingresaba con su propio código. Aplica a expulsar
    /// Y a salir (quien ya no está en el viaje no debe tener códigos activos a su nombre).
    public func quitarMiembro(_ memberId: MiembroId, de tripId: String, ahora: Date) async throws {
        try await client.withTransaction(logger: logger) { conn in
            _ = try await conn.query("""
                UPDATE trip_members SET left_at = \(ahora)
                WHERE trip_id = \(tripId) AND member_id = \(memberId.raw) AND left_at IS NULL
                """, logger: self.logger)
            _ = try await conn.query("""
                UPDATE trip_invites SET revoked_at = \(ahora)
                WHERE trip_id = \(tripId) AND created_by = \(memberId.raw) AND revoked_at IS NULL
                """, logger: self.logger)
            // Limpia el estado de reserva de ese miembro en ESE viaje (Task 5, wedge
            // "quién ya reservó", migración 0008): mismo criterio "expulsar revoca huella"
            // que arriba con las invitaciones, en la MISMA transacción. `cada_uno` pierde
            // su fila en itinerary_reservation_members; si era el responsable de un
            // uno_para_todos, vuelve a quedar sin asignar (pendiente, no "de nadie").
            _ = try await conn.query("""
                DELETE FROM itinerary_reservation_members
                WHERE member_id = \(memberId.raw)
                  AND activity_id IN (SELECT activity_id FROM itinerary_reservations WHERE trip_id = \(tripId))
                """, logger: self.logger)
            _ = try await conn.query("""
                UPDATE itinerary_reservations SET responsible_id = NULL, single_estado = 'pendiente'
                WHERE trip_id = \(tripId) AND responsible_id = \(memberId.raw)
                """, logger: self.logger)
        }
    }

    public func cerrar(tripId: String, ahora: Date) async throws {
        _ = try await client.query(
            "UPDATE trips SET closed_at = \(ahora) WHERE id = \(tripId)", logger: logger)
    }

    // MARK: - Sucesión de ownership (enmienda ADR-0018, decisión de Andrea 2026-07-27)

    /// `ORDER BY joined_at ASC, member_id ASC`: mismo desempate estable que
    /// `miembros(de:)` usa para `member_id` solo, aplicado aquí tras la antigüedad
    /// real. `LIMIT 1` — solo se necesita el más antiguo.
    public func miembroActivoMasAntiguo(de tripId: String, excluyendo actor: MiembroId) async throws -> MiembroId? {
        let rows = try await client.query("""
            SELECT member_id FROM trip_members
            WHERE trip_id = \(tripId) AND left_at IS NULL AND member_id != \(actor.raw)
            ORDER BY joined_at ASC, member_id ASC
            LIMIT 1
            """, logger: logger)
        for try await (memberId) in rows.decode(String.self) {
            return MiembroId(memberId)
        }
        return nil
    }

    /// `WHERE ... left_at IS NULL`: no-op si `memberId` ya no está activo (mismo
    /// principio de idempotencia que `quitarMiembro`/`revocarInvitacion`).
    public func promoverAOwner(_ memberId: MiembroId, en tripId: String) async throws {
        _ = try await client.query("""
            UPDATE trip_members SET role = 'owner'
            WHERE trip_id = \(tripId) AND member_id = \(memberId.raw) AND left_at IS NULL
            """, logger: logger)
    }
}
