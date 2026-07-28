// Adaptador Postgres de ItinerarioRepositorio (M5, ADR-0020 borrador —
// docs/design/itinerario-scope-y-plan.md; ETag/If-Match añadido por el bead
// 201, migración 0010). Mapea contra la migración 0005 (itinerary_items).
// Mismo patrón que RepositorioVotacionPostgres.swift: client.query con binds
// interpolados = seguros; sin transacción porque cada operación es una única
// sentencia (`actualizar` no necesita transacción explícita: el UPDATE
// condicional por etag en el WHERE es atómico por sí mismo — mismo patrón que
// `RepositorioPostgres.actualizar` de gastos — no hay lectura-antes-de-escribir
// que proteger de TOCTOU).
//
// Decisión sobre `day` (columna `date`, dominio la modela como String
// 'YYYY-MM-DD', plan §Contrato de dominio): PostgresNIO decodificaría una
// columna `date` como `PostgresDate`/`Date`, no como `String`, así que:
//   - LECTURA: se castea explícitamente con `day::text` en el SELECT. Postgres
//     con `datestyle` por defecto (ISO, MDY) formatea `date::text` siempre como
//     'YYYY-MM-DD' — no depende de locale de sesión. Así el driver decodifica
//     directo a `String` sin pasar por `PostgresDate`/`Foundation.Date` ni
//     arrastrar husos horarios.
//   - ESCRITURA: se interpola el String tal cual y se le añade `::date` en el
//     INSERT/UPDATE; Postgres valida y castea 'YYYY-MM-DD' -> date. Si el
//     String no fuera un date válido, el cast falla en la propia BD (defensa
//     en profundidad, aunque el caso de uso ya debería validarlo antes).

import Foundation
import Logging
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses

extension RepositorioPostgres: ItinerarioRepositorio {

    // MARK: - Crear

    public func crear(_ a: ActividadItinerario, ahora: Date) async throws -> ActividadConEtag {
        let etag = UUID().uuidString
        // `a.createdBy` es el actor que crea -> enTransaccionConRol(actor:) explícito.
        try await client.enTransaccionConRol(actor: a.createdBy, logger: logger) { conn in
            _ = try await conn.query("""
                INSERT INTO itinerary_items
                    (id, trip_id, title, day, start_time, location, notes, order_index, created_by, etag, created_at, updated_at)
                VALUES
                    (\(a.id), \(a.tripId), \(a.title), \(a.day)::date, \(a.startTime), \(a.location), \(a.notes),
                     \(a.orderIndex), \(a.createdBy.raw), \(etag), \(ahora), \(ahora))
                """, logger: self.logger)
        }
        return ActividadConEtag(actividad: a, etag: etag)
    }

    // MARK: - Leer

    /// Orden `(day, order_index, id)` — mismo criterio que el puerto (plan §Contrato
    /// de dominio); el cliente añade `startTime` como desempate fuera del dominio.
    /// El `id` final NO es cosmético: `(day, order_index)` no desempata (nada impide
    /// dos actividades del mismo día con el mismo índice), y con un orden no total el
    /// `LIMIT` puede devolver un subconjunto distinto en cada consulta.
    /// `limit` llega ya clampado de `CasosDeUsoItinerario.listar`.
    public func listar(_ tripId: String, limit: Int) async throws -> [ActividadConEtag] {
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            let rows = try await conn.query("""
                SELECT id, trip_id, title, day::text, start_time, location, notes, order_index, created_by, etag
                FROM itinerary_items
                WHERE trip_id = \(tripId)
                ORDER BY day, order_index, id
                LIMIT \(limit)
                """, logger: self.logger)
            var out: [ActividadConEtag] = []
            for try await (id, tripId, title, day, startTime, location, notes, orderIndex, createdBy, etag)
                in rows.decode((String, String, String, String, String?, String?, String?, Int, String, String).self) {
                let actividad = ActividadItinerario(
                    id: id, tripId: tripId, title: title, day: day, startTime: startTime,
                    location: location, notes: notes, orderIndex: orderIndex, createdBy: MiembroId(createdBy))
                out.append(ActividadConEtag(actividad: actividad, etag: etag))
            }
            return out
        }
    }

    /// Lectura "cruda" sin etag (autorización/merge parcial, ver el puerto).
    public func item(id: String, en tripId: String) async throws -> ActividadItinerario? {
        try await client.enTransaccionConRolActual(logger: logger) { conn in
            let rows = try await conn.query("""
                SELECT id, trip_id, title, day::text, start_time, location, notes, order_index, created_by
                FROM itinerary_items
                WHERE id = \(id) AND trip_id = \(tripId)
                """, logger: self.logger)
            for try await (id, tripId, title, day, startTime, location, notes, orderIndex, createdBy)
                in rows.decode((String, String, String, String, String?, String?, String?, Int, String).self) {
                return ActividadItinerario(
                    id: id, tripId: tripId, title: title, day: day, startTime: startTime,
                    location: location, notes: notes, orderIndex: orderIndex, createdBy: MiembroId(createdBy))
            }
            return nil
        }
    }

    // MARK: - Actualizar / borrar

    /// UPDATE condicional ATÓMICO por etag (bead 201, mismo patrón que
    /// `RepositorioPostgres.actualizar` de gastos): el etag va en el WHERE, así dos
    /// PATCH concurrentes con el mismo `If-Match` no se pisan — solo uno encuentra la
    /// fila con ese etag, el otro afecta 0 filas y se distingue not-found/conflicto
    /// leyendo el etag actual.
    public func actualizar(_ a: ActividadItinerario, ifMatch etag: String, ahora: Date) async throws -> ResultadoEscrituraItinerario {
        let nuevoEtag = UUID().uuidString
        return try await client.enTransaccionConRolActual(logger: logger) { conn in
            let upd = try await conn.query("""
                UPDATE itinerary_items
                SET title = \(a.title), day = \(a.day)::date, start_time = \(a.startTime),
                    location = \(a.location), notes = \(a.notes), order_index = \(a.orderIndex),
                    etag = \(nuevoEtag), updated_at = \(ahora)
                WHERE id = \(a.id) AND trip_id = \(a.tripId) AND etag = \(etag)
                RETURNING etag
                """, logger: self.logger)
            var actualizado = false
            for try await _ in upd.decode(String.self) { actualizado = true }
            guard actualizado else {
                // 0 filas: o no existe (borrada/otro trip) o el etag no coincide (conflicto).
                if let actual = try await self.etagActual(conn, id: a.id, en: a.tripId) {
                    return .conflicto(serverEtag: actual)
                }
                return .noEncontrado
            }
            return .ok(ActividadConEtag(actividad: a, etag: nuevoEtag))
        }
    }

    private func etagActual(_ conn: PostgresConnection, id: String, en tripId: String) async throws -> String? {
        let rows = try await conn.query(
            "SELECT etag FROM itinerary_items WHERE id = \(id) AND trip_id = \(tripId)",
            logger: logger)
        for try await (e) in rows.decode(String.self) { return e }
        return nil
    }

    public func borrar(id: String, en tripId: String, por actor: MiembroId) async throws -> Bool {
        // Bead 48g (hallazgo Codex #58): DELETE scopeado por membresía ACTUAL en el mismo
        // statement (CTE) Y bloqueando `trip_members` con `FOR SHARE` para serializar contra un
        // `quitarMiembro` concurrente. Ver `RepositorioChatPostgres.borrar` para el detalle.
        // `por actor` es quien borra -> enTransaccionConRol(actor:) explícito.
        try await client.enTransaccionConRol(actor: actor, logger: logger) { conn in
            let rows = try await conn.query("""
                WITH miembro AS (
                    SELECT 1 FROM trip_members
                    WHERE trip_id = \(tripId) AND member_id = \(actor.raw) AND left_at IS NULL
                    FOR SHARE
                ),
                borrado AS (
                    DELETE FROM itinerary_items
                    WHERE id = \(id) AND trip_id = \(tripId) AND EXISTS(SELECT 1 FROM miembro)
                    RETURNING 1
                )
                SELECT EXISTS(SELECT 1 FROM miembro) AS es_miembro
                """, logger: self.logger)
            for try await (esMiembro) in rows.decode(Bool.self) { return esMiembro }
            return false
        }
    }
}
