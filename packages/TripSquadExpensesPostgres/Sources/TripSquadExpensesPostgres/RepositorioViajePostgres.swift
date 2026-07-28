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
        // El actor RLS es el `creador` (lo lleva la firma, como la familia `guardar`): se
        // usa `enTransaccionConRol(actor:)` explícito. La policy `trips_insert` exige
        // created_by = uid() y `trip_members_insert` (rama bootstrap) exige es_creador +
        // viaje sin miembros — ambas se cumplen para el creador entrante.
        try await client.enTransaccionConRol(actor: creador, logger: logger) { conn in
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
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            let rows = try await conn.query(
                "SELECT name, base_currency, created_by, closed_at FROM trips WHERE id = \(id)",
                logger: self.logger)
            for try await (name, baseCurrency, createdBy, closedAt) in rows.decode((String, String, String, Date?).self) {
                return Viaje(id: id, name: name, baseCurrency: baseCurrency, createdBy: MiembroId(createdBy), closedAt: closedAt)
            }
            return nil
        }
    }

    /// `ORDER BY t.id` (antes `t.created_at`): el adaptador en memoria ordenaba por
    /// `id` y este por `created_at` — dos órdenes distintos para el mismo listado, y
    /// además `created_at` no es único (dos viajes creados en el mismo tick empatan sin
    /// desempate). Se unifica al `id` porque `Viaje` (dominio) NO lleva `createdAt`:
    /// ordenar por fecha aquí sería un criterio que memoria no puede reproducir.
    /// `limit` llega ya clampado de `CasosDeUsoViaje.misViajes`.
    public func viajesDe(_ actor: MiembroId, limit: Int) async throws -> [Viaje] {
        // "mis viajes": el `actor` es el propio usuario -> enTransaccionConRol(actor:) explícito.
        try await client.enTransaccionConRol(actor: actor, logger: logger) { conn in
            let rows = try await conn.query("""
                SELECT t.id, t.name, t.base_currency, t.created_by, t.closed_at
                FROM trips t
                JOIN trip_members m ON m.trip_id = t.id
                WHERE m.member_id = \(actor.raw) AND m.left_at IS NULL
                ORDER BY t.id
                LIMIT \(limit)
                """, logger: self.logger)
            var out: [Viaje] = []
            for try await (id, name, baseCurrency, createdBy, closedAt) in rows.decode((String, String, String, String, Date?).self) {
                out.append(Viaje(id: id, name: name, baseCurrency: baseCurrency, createdBy: MiembroId(createdBy), closedAt: closedAt))
            }
            return out
        }
    }

    // MARK: - Miembros / roles

    /// `ORDER BY member_id`: sin él Postgres devolvía el orden físico del heap
    /// (cambia con cada UPDATE de `left_at`) mientras memoria sí ordenaba — la lista de
    /// miembros del mismo viaje salía distinta según el adaptador. Sin `LIMIT`: el
    /// tamaño ya está acotado por el tope de 50 miembros (ADR-0018 §8).
    public func miembros(de tripId: String) async throws -> [(MiembroId, RolMiembro)] {
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            let rows = try await conn.query(
                "SELECT member_id, role FROM trip_members WHERE trip_id = \(tripId) AND left_at IS NULL ORDER BY member_id",
                logger: self.logger)
            var out: [(MiembroId, RolMiembro)] = []
            for try await (memberId, role) in rows.decode((String, String).self) {
                guard let rol = RolMiembro(rawValue: role) else { continue }
                out.append((MiembroId(memberId), rol))
            }
            return out
        }
    }

    /// `nil` = no es miembro activo — ÚNICA fuente de verdad de autorización de
    /// este dominio (ver doc de `ViajeRepositorio`), indistinguible desde fuera
    /// de "el viaje no existe".
    public func rol(de actor: MiembroId, en tripId: String) async throws -> RolMiembro? {
        // "mi rol en este viaje": el `actor` es el propio usuario -> explícito.
        try await client.enTransaccionConRol(actor: actor, logger: logger) { conn in
            let rows = try await conn.query(
                "SELECT role FROM trip_members WHERE trip_id = \(tripId) AND member_id = \(actor.raw) AND left_at IS NULL",
                logger: self.logger)
            for try await (role) in rows.decode(String.self) {
                return RolMiembro(rawValue: role)
            }
            return nil
        }
    }

    // MARK: - Invitaciones

    public func crearInvitacion(tripId: String, por: MiembroId, code: String, expiresAt: Date) async throws -> Invitacion {
        // `por` es el actor que emite la invitación (debe ser miembro) -> explícito.
        try await client.enTransaccionConRol(actor: por, logger: logger) { conn in
            _ = try await conn.query("""
                INSERT INTO trip_invites (code, trip_id, created_by, expires_at)
                VALUES (\(code), \(tripId), \(por.raw), \(expiresAt))
                """, logger: self.logger)
        }
        return Invitacion(code: code, tripId: tripId, createdBy: por, expiresAt: expiresAt, revokedAt: nil)
    }

    public func revocarInvitacion(code: String, en tripId: String, ahora: Date) async throws -> Bool {
        // Idempotente (igual que RepositorioEnMemoria, hallazgo Codex P3): revoca si no lo
        // estaba (coalesce conserva el revoked_at original), y devuelve true si la
        // invitación existe en ESE viaje — ya revocada o recién revocada. false solo si el
        // code no existe o es de otro viaje.
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            let rows = try await conn.query("""
                UPDATE trip_invites SET revoked_at = coalesce(revoked_at, \(ahora))
                WHERE code = \(code) AND trip_id = \(tripId)
                RETURNING code
                """, logger: self.logger)
            for try await _ in rows { return true }
            return false
        }
    }

    // MARK: - Unirse

    /// Todo en una transacción (spec del brief): código válido/vivo/no-revocado,
    /// viaje abierto, membresía previa y tope se comprueban contra la misma foto
    /// consistente antes de mutar `trip_members` — evita carreras entre el check
    /// y la escritura.
    ///
    /// Enrutado RLS (bead RLS-enrutado): quien entra AÚN no es miembro, así que la RLS de
    /// `trip_invites`/`trips`/`trip_members` le ocultaría el código, el viaje y el conteo.
    /// Por eso las LECTURAS de bootstrap (resolver el code + closed_at + tope + su propia
    /// fila) van por `private.invitacion_por_codigo` (security definer, 0015), que además
    /// bloquea la fila del viaje `FOR UPDATE` (misma protección del tope que antes). El
    /// WRITE de la membresía SÍ va como el actor entrante (rama de invitación de la policy
    /// `trip_members_insert`, ADR-0030 / 0014 §3.2).
    public func unirsePorCodigo(code: String, actor: MiembroId, ahora: Date, tope: Int) async throws -> ResultadoUnirse {
        // El actor entrante lo lleva la firma -> enTransaccionConRol(actor:) explícito. La
        // rama de invitación de `trip_members_insert` exige member_id = uid() = actor.
        try await client.enTransaccionConRol(actor: actor, logger: logger) { conn in
            let ctx = try await conn.query("""
                SELECT trip_id, closed_at, activos, existe_fila, es_activo, estado
                FROM private.invitacion_por_codigo(\(code), \(ahora))
                """, logger: self.logger)
            var tripId: String?
            var closedAt: Date?
            var activos = 0
            var existeFila = false
            var esActivo = false
            var estado = "invalido"
            for try await (t, c, a, ef, ea, e) in ctx.decode((String?, Date?, Int, Bool, Bool, String).self) {
                tripId = t; closedAt = c; activos = a; existeFila = ef; esActivo = ea; estado = e
            }
            switch estado {
            case "revocado": return .revocado
            case "caducado": return .caducado
            case "ok": break
            default: return .codigoInvalido
            }
            guard let tripId else { return .codigoInvalido }
            if closedAt != nil { return .viajeCerrado }
            if esActivo { return .yaMiembro }
            if activos >= tope { return .lleno }

            // Alta nueva O reingreso (miembro que salió), TODO por `private.unirse_por_invitacion`
            // (security definer, 0015) con el `ahora` INYECTADO (P1/P2 Codex #63): así el reloj de
            // la validación de caducidad coincide con el de `invitacion_por_codigo` (que ya validó
            // el código) y no diverge del `now()` de la BD que usaría la policy en el INSERT/UPDATE.
            // La reactivación (left_at=NULL) el propio usuario NO la puede hacer bajo la RLS
            // (rol_en_viaje es NULL mientras está inactivo → WITH CHECK falla), y el alta nueva por
            // la policy usaría `now()`; la secdef unifica ambos con `p_ahora`. `existeFila` ya no
            // decide el camino (la secdef distingue reactivar vs insertar), pero se conserva en el
            // resolver para los estados `yaMiembro`/`caducado`.
            let filas = try await conn.query(
                "SELECT private.unirse_por_invitacion(\(tripId), \(code), \(actor.raw), \(ahora))",
                logger: self.logger)
            var escrito = false
            for try await (b) in filas.decode(Bool.self) { escrito = b }
            // Si NO escribió membresía, la invitación se revocó/caducó en la carrera (READ
            // COMMITTED) entre `invitacion_por_codigo` y la escritura → no se unió (P2 Codex #63):
            // devolver un fallo en vez de `.unido` a ciegas.
            guard escrito else { return .revocado }
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
        // El actor (owner que expulsa, o el propio miembro que sale) fija el contexto RLS:
        // las policies `trip_members`/`trip_invites`/`itinerary_reservations*` permiten al
        // owner gestionar y al propio miembro salir.
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            // ORDEN (P1 Codex #63): las limpiezas van ANTES de desactivar la membresía. En una
            // AUTO-SALIDA (actor == memberId) el UPDATE de `left_at` haría `es_miembro(self)`
            // falso, y las policies RLS de trip_invites/reservas filtrarían a CERO las limpiezas
            // siguientes → las invitaciones propias seguirían vivas (reingreso con el propio
            // código) y la huella de reservas no se limpiaría. Ejecutándolas primero, el actor
            // (que sale, o el owner que expulsa) SIGUE siendo miembro y la RLS las permite; el
            // `left_at` se pone al final. Todo en la MISMA transacción (atómico).
            _ = try await conn.query("""
                UPDATE trip_invites SET revoked_at = \(ahora)
                WHERE trip_id = \(tripId) AND created_by = \(memberId.raw) AND revoked_at IS NULL
                """, logger: self.logger)
            // `cada_uno` pierde su fila en itinerary_reservation_members; si era el responsable
            // de un uno_para_todos, vuelve a quedar sin asignar (pendiente, no "de nadie").
            _ = try await conn.query("""
                DELETE FROM itinerary_reservation_members
                WHERE member_id = \(memberId.raw)
                  AND activity_id IN (SELECT activity_id FROM itinerary_reservations WHERE trip_id = \(tripId))
                """, logger: self.logger)
            _ = try await conn.query("""
                UPDATE itinerary_reservations SET responsible_id = NULL, single_estado = 'pendiente'
                WHERE trip_id = \(tripId) AND responsible_id = \(memberId.raw)
                """, logger: self.logger)
            // Desactivación de la membresía AL FINAL (ver nota de orden arriba).
            _ = try await conn.query("""
                UPDATE trip_members SET left_at = \(ahora)
                WHERE trip_id = \(tripId) AND member_id = \(memberId.raw) AND left_at IS NULL
                """, logger: self.logger)
        }
    }

    public func cerrar(tripId: String, ahora: Date) async throws {
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            _ = try await conn.query(
                "UPDATE trips SET closed_at = \(ahora) WHERE id = \(tripId)", logger: self.logger)
        }
    }

    // MARK: - Sucesión de ownership (enmienda ADR-0018, decisión de Andrea 2026-07-27)

    /// `ORDER BY joined_at ASC, member_id ASC`: mismo desempate estable que
    /// `miembros(de:)` usa para `member_id` solo, aplicado aquí tras la antigüedad
    /// real. `LIMIT 1` — solo se necesita el más antiguo.
    public func miembroActivoMasAntiguo(de tripId: String, excluyendo actor: MiembroId) async throws -> MiembroId? {
        // Actor = el owner saliente (aún miembro activo cuando se llama, antes de salir): lo
        // lleva la firma -> explícito. Su contexto RLS permite leer los miembros (es_miembro).
        try await client.enTransaccionConRol(actor: actor, logger: logger) { conn in
            let rows = try await conn.query("""
                SELECT member_id FROM trip_members
                WHERE trip_id = \(tripId) AND left_at IS NULL AND member_id != \(actor.raw)
                ORDER BY joined_at ASC, member_id ASC
                LIMIT 1
                """, logger: self.logger)
            for try await (memberId) in rows.decode(String.self) {
                return MiembroId(memberId)
            }
            return nil
        }
    }

    /// `WHERE ... left_at IS NULL`: no-op si `memberId` ya no está activo (mismo
    /// principio de idempotencia que `quitarMiembro`/`revocarInvitacion`).
    ///
    /// Actor = el owner saliente (todavía owner cuando promueve al sucesor): la policy
    /// `trip_members_update` permite al owner gestionar el rol de terceros.
    public func promoverAOwner(_ memberId: MiembroId, en tripId: String) async throws {
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            _ = try await conn.query("""
                UPDATE trip_members SET role = 'owner'
                WHERE trip_id = \(tripId) AND member_id = \(memberId.raw) AND left_at IS NULL
                """, logger: self.logger)
        }
    }
}
