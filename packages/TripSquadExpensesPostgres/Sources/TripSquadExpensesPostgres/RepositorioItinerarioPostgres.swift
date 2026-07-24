// Adaptador Postgres de ItinerarioRepositorio (M5, ADR-0020 borrador —
// docs/design/itinerario-scope-y-plan.md). Mapea contra la migración 0005
// (itinerary_items). Mismo patrón que RepositorioVotacionPostgres.swift:
// client.query con binds interpolados = seguros; sin transacción porque cada
// operación es una única sentencia (no hay lectura-antes-de-escribir que
// proteger de TOCTOU, a diferencia de `votar`).
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

    public func crear(_ a: ActividadItinerario, ahora: Date) async throws {
        _ = try await client.query("""
            INSERT INTO itinerary_items
                (id, trip_id, title, day, start_time, location, notes, order_index, created_by, created_at, updated_at)
            VALUES
                (\(a.id), \(a.tripId), \(a.title), \(a.day)::date, \(a.startTime), \(a.location), \(a.notes),
                 \(a.orderIndex), \(a.createdBy.raw), \(ahora), \(ahora))
            """, logger: logger)
    }

    // MARK: - Leer

    /// Orden `(day, order_index)` — mismo criterio que el puerto (plan §Contrato
    /// de dominio); el cliente añade `startTime` como desempate fuera del dominio.
    public func listar(_ tripId: String) async throws -> [ActividadItinerario] {
        let rows = try await client.query("""
            SELECT id, trip_id, title, day::text, start_time, location, notes, order_index, created_by
            FROM itinerary_items
            WHERE trip_id = \(tripId)
            ORDER BY day, order_index
            """, logger: logger)
        var out: [ActividadItinerario] = []
        for try await (id, tripId, title, day, startTime, location, notes, orderIndex, createdBy)
            in rows.decode((String, String, String, String, String?, String?, String?, Int, String).self) {
            out.append(ActividadItinerario(
                id: id, tripId: tripId, title: title, day: day, startTime: startTime,
                location: location, notes: notes, orderIndex: orderIndex, createdBy: MiembroId(createdBy)))
        }
        return out
    }

    public func item(id: String, en tripId: String) async throws -> ActividadItinerario? {
        let rows = try await client.query("""
            SELECT id, trip_id, title, day::text, start_time, location, notes, order_index, created_by
            FROM itinerary_items
            WHERE id = \(id) AND trip_id = \(tripId)
            """, logger: logger)
        for try await (id, tripId, title, day, startTime, location, notes, orderIndex, createdBy)
            in rows.decode((String, String, String, String, String?, String?, String?, Int, String).self) {
            return ActividadItinerario(
                id: id, tripId: tripId, title: title, day: day, startTime: startTime,
                location: location, notes: notes, orderIndex: orderIndex, createdBy: MiembroId(createdBy))
        }
        return nil
    }

    // MARK: - Actualizar / borrar

    public func actualizar(_ a: ActividadItinerario, ahora: Date) async throws {
        _ = try await client.query("""
            UPDATE itinerary_items
            SET title = \(a.title), day = \(a.day)::date, start_time = \(a.startTime),
                location = \(a.location), notes = \(a.notes), order_index = \(a.orderIndex), updated_at = \(ahora)
            WHERE id = \(a.id) AND trip_id = \(a.tripId)
            """, logger: logger)
    }

    public func borrar(id: String, en tripId: String) async throws {
        _ = try await client.query(
            "DELETE FROM itinerary_items WHERE id = \(id) AND trip_id = \(tripId)",
            logger: logger)
    }
}
