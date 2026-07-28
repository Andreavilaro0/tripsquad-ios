// Adaptador Postgres de ReservaRepositorio (wedge "quién ya reservó",
// spec docs/superpowers/specs/2026-07-25-wedge-reserva-por-persona-design.md, Task 4). Mapea contra
// la migración 0008 (itinerary_reservations + itinerary_reservation_members)
// y, para confirmaciones (dy5), la migración 0009 (itinerary_reservation_confirmations).
// Mismo patrón que RepositorioItinerarioPostgres.swift: client.query con
// binds interpolados = seguros.
//
// `guardarConfirmacion`/`confirmacion` (dy5, Task 4): la confirmación cuelga
// por FK de `itinerary_reservations.activity_id` (0009), así que exige que el
// aspecto reserva de la actividad ya exista (`upsert` primero). `confirmacion`
// hace JOIN con `itinerary_reservations` para verificar el `tripId` (la tabla
// de confirmaciones no repite esa columna).
//
// El aspecto reserva vive en DOS tablas porque el modo (`cada_uno` /
// `uno_para_todos`) tiene forma distinta (ADR de dominio en Reserva.swift):
//   - `itinerary_reservations` (1 fila por actividad): kind + mode +
//     responsible_id/single_estado (solo rellenos en uno_para_todos).
//   - `itinerary_reservation_members` (0..N filas): estados por miembro,
//     solo pobladas en cada_uno.
//
// `upsert` REEMPLAZA el aspecto completo (spec del puerto): en transacción,
// UPSERT de la fila principal + DELETE/re-INSERT de los miembros — nunca
// mergea participantes viejos con nuevos (si no, un upsert de cada_uno con
// menos miembros dejaría filas rancias, o un cambio de modo a uno_para_todos
// dejaría miembros huérfanos que corromperían la reconstrucción al leer).
//
// `marcarEstado` REPLICA el comportamiento de RepositorioEnMemoria
// (RepositorioEnMemoria.swift, extension ReservaRepositorio): la rama que se
// ejecuta depende del modo GUARDADO, no de si `miembro` es nil o no.
//   - Guardado `cada_uno`: solo actúa si `miembro` viene informado (si no,
//     no-op silencioso); si el miembro no estaba incluido, el UPDATE afecta
//     0 filas (mismo "no se añade" que el diccionario en memoria).
//   - Guardado `uno_para_todos`: SIEMPRE fija `single_estado`, ignorando
//     `miembro` si viniera informado (igual que el `case .unoParaTodos` en
//     memoria, que no mira el parámetro).
// Ambas ramas leen el modo dentro de la MISMA transacción en la que escriben
// (evita una foto obsoleta si otra petición cambia el modo entre medias).

import Foundation
import Logging
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses

/// Fila cruda de `itinerary_reservations` antes de reconstruir el `Reserva` de
/// dominio (sustituye una tupla de 5 miembros — `large_tuple` de SwiftLint).
private struct FilaReservaHeader {
    let activityId: String
    let kind: String
    let mode: String
    let responsibleId: String?
    let singleEstado: String?
}

extension RepositorioPostgres: ReservaRepositorio {

    // MARK: - Upsert

    public func upsert(_ r: Reserva, ahora: Date) async throws {
        let (modeRaw, responsibleId, singleEstado) = Self.modoASQL(r.mode)

        try await client.withTransaction(logger: logger) { conn in
            _ = try await conn.query("""
                INSERT INTO itinerary_reservations
                    (activity_id, trip_id, kind, mode, responsible_id, single_estado, created_at)
                VALUES
                    (\(r.activityId), \(r.tripId), \(r.kind.rawValue), \(modeRaw), \(responsibleId), \(singleEstado), \(ahora))
                ON CONFLICT (activity_id) DO UPDATE SET
                    trip_id = EXCLUDED.trip_id,
                    kind = EXCLUDED.kind,
                    mode = EXCLUDED.mode,
                    responsible_id = EXCLUDED.responsible_id,
                    single_estado = EXCLUDED.single_estado
                """, logger: self.logger)

            // Reemplazo total de participantes: borra e inserta, nunca mergea
            // (si el nuevo modo es uno_para_todos, esto también limpia los
            // miembros que hubiera de un cada_uno anterior).
            _ = try await conn.query(
                "DELETE FROM itinerary_reservation_members WHERE activity_id = \(r.activityId)",
                logger: self.logger)

            if case .cadaUnoElSuyo(let estados) = r.mode {
                for (miembro, estado) in estados {
                    _ = try await conn.query("""
                        INSERT INTO itinerary_reservation_members (activity_id, member_id, estado)
                        VALUES (\(r.activityId), \(miembro.raw), \(estado.rawValue))
                        """, logger: self.logger)
                }
            }
        }
    }

    // MARK: - Leer

    public func reserva(activityId: String, en tripId: String) async throws -> Reserva? {
        let rows = try await client.query("""
            SELECT kind, mode, responsible_id, single_estado
            FROM itinerary_reservations
            WHERE activity_id = \(activityId) AND trip_id = \(tripId)
            """, logger: logger)
        for try await (kind, mode, responsibleId, singleEstado)
            in rows.decode((String, String, String?, String?).self) {
            let estados = mode == "cada_uno" ? try await miembrosDe(activityId) : [:]
            return try Self.reconstruir(
                activityId: activityId, tripId: tripId, kind: kind, mode: mode,
                responsibleId: responsibleId, singleEstado: singleEstado, estados: estados)
        }
        return nil
    }

    /// SIN tope (mismo criterio que `RepositorioEnMemoria.tablero`: el nº de
    /// actividades ya está acotado por el itinerario). Orden estable por
    /// `activity_id`. UNA sola query extra para los miembros de TODAS las
    /// actividades `cada_uno` del tablero (evita N+1).
    public func tablero(_ tripId: String) async throws -> [Reserva] {
        let rows = try await client.query("""
            SELECT activity_id, kind, mode, responsible_id, single_estado
            FROM itinerary_reservations
            WHERE trip_id = \(tripId)
            ORDER BY activity_id
            """, logger: logger)
        var base: [FilaReservaHeader] = []
        for try await (activityId, kind, mode, responsibleId, singleEstado)
            in rows.decode((String, String, String, String?, String?).self) {
            base.append(FilaReservaHeader(
                activityId: activityId, kind: kind, mode: mode,
                responsibleId: responsibleId, singleEstado: singleEstado))
        }
        guard !base.isEmpty else { return [] }

        let memberRows = try await client.query("""
            SELECT m.activity_id, m.member_id, m.estado
            FROM itinerary_reservation_members m
            JOIN itinerary_reservations r ON r.activity_id = m.activity_id
            WHERE r.trip_id = \(tripId)
            """, logger: logger)
        var miembrosPorActividad: [String: [MiembroId: EstadoReserva]] = [:]
        for try await (activityId, memberId, estado) in memberRows.decode((String, String, String).self) {
            miembrosPorActividad[activityId, default: [:]][MiembroId(memberId)] = EstadoReserva(rawValue: estado) ?? .pendiente
        }

        return try base.map { fila in
            try Self.reconstruir(
                activityId: fila.activityId, tripId: tripId, kind: fila.kind, mode: fila.mode,
                responsibleId: fila.responsibleId, singleEstado: fila.singleEstado,
                estados: miembrosPorActividad[fila.activityId] ?? [:])
        }
    }

    // MARK: - marcarEstado

    /// Ver comentario de cabecera: la rama depende del modo GUARDADO, no del
    /// parámetro `miembro` — réplica exacta de `RepositorioEnMemoria`.
    public func marcarEstado(activityId: String, en tripId: String, miembro: MiembroId?, estado: EstadoReserva) async throws {
        try await client.withTransaction(logger: logger) { conn in
            let rows = try await conn.query("""
                SELECT mode FROM itinerary_reservations
                WHERE activity_id = \(activityId) AND trip_id = \(tripId)
                """, logger: self.logger)
            var modoGuardado: String?
            for try await (m) in rows.decode(String.self) { modoGuardado = m }
            guard let modoGuardado else { return }   // no existe -> no-op (mismo criterio que memoria)

            if modoGuardado == "cada_uno" {
                guard let miembro else { return }
                _ = try await conn.query("""
                    UPDATE itinerary_reservation_members SET estado = \(estado.rawValue)
                    WHERE activity_id = \(activityId) AND member_id = \(miembro.raw)
                    """, logger: self.logger)
            } else {
                _ = try await conn.query("""
                    UPDATE itinerary_reservations SET single_estado = \(estado.rawValue)
                    WHERE activity_id = \(activityId) AND trip_id = \(tripId)
                    """, logger: self.logger)
            }
        }
    }

    // MARK: - Borrar

    /// `itinerary_reservation_members` se limpia sola por el `ON DELETE
    /// CASCADE` de la migración 0008 (FK a `itinerary_reservations.activity_id`).
    public func borrar(activityId: String, en tripId: String, por actor: MiembroId) async throws -> Bool {
        // Bead 48g (hallazgo Codex #58): DELETE del aspecto reserva scopeado por membresía ACTUAL
        // en el mismo statement (CTE) Y bloqueando `trip_members` con `FOR SHARE` para serializar
        // contra un `quitarMiembro` concurrente. Sigue siendo idempotente (quitar un aspecto
        // ausente con membresía vigente devuelve true). Ver `RepositorioChatPostgres.borrar`.
        let rows = try await client.query("""
            WITH miembro AS (
                SELECT 1 FROM trip_members
                WHERE trip_id = \(tripId) AND member_id = \(actor.raw) AND left_at IS NULL
                FOR SHARE
            ),
            borrado AS (
                DELETE FROM itinerary_reservations
                WHERE activity_id = \(activityId) AND trip_id = \(tripId) AND EXISTS(SELECT 1 FROM miembro)
                RETURNING 1
            )
            SELECT EXISTS(SELECT 1 FROM miembro) AS es_miembro
            """, logger: logger)
        for try await (esMiembro) in rows.decode(Bool.self) { return esMiembro }
        return false
    }

    // MARK: - Confirmaciones (dy5)

    /// Reemplaza si ya existía (mismo criterio que `upsert` de `Reserva`).
    /// Requiere que ya exista el aspecto reserva de la actividad (FK de la
    /// migración 0009 a `itinerary_reservations.activity_id`).
    public func guardarConfirmacion(activityId: String, en tripId: String, miembro: MiembroId, _ c: Confirmacion) async throws {
        _ = try await client.query("""
            INSERT INTO itinerary_reservation_confirmations
                (activity_id, member_id, tipo, fecha_iso, numero_confirmacion, proveedor, created_at)
            VALUES
                (\(activityId), \(miembro.raw), \(c.tipo.rawValue), \(c.fechaISO), \(c.numeroConfirmacion), \(c.proveedor), \(Date()))
            ON CONFLICT (activity_id, member_id) DO UPDATE SET
                tipo = EXCLUDED.tipo,
                fecha_iso = EXCLUDED.fecha_iso,
                numero_confirmacion = EXCLUDED.numero_confirmacion,
                proveedor = EXCLUDED.proveedor,
                created_at = EXCLUDED.created_at
            """, logger: logger)
    }

    /// Endurecimiento a62 (atomicidad, ADR-0028): guarda la confirmación Y marca
    /// el estado `.reservado` en la MISMA transacción, de modo que un fallo entre
    /// medias no pueda dejar "confirmación guardada + estado pendiente" (antes
    /// eran dos llamadas de puerto con transacción propia cada una). El UPSERT de
    /// la confirmación es idéntico a `guardarConfirmacion`; el marcado replica
    /// `marcarEstado` (rama por modo GUARDADO, leído dentro de la misma
    /// transacción). El actor sube su propia confirmación, así que se usa
    /// `miembro` para el marcado — en `uno_para_todos` la rama lo ignora y fija
    /// `single_estado` (mismo criterio que `marcarEstado`).
    public func guardarConfirmacionYMarcarReservado(activityId: String, en tripId: String, miembro: MiembroId, _ c: Confirmacion) async throws {
        try await client.withTransaction(logger: logger) { conn in
            // 1. Guarda la confirmación (upsert por PK (activity_id, member_id)).
            _ = try await conn.query("""
                INSERT INTO itinerary_reservation_confirmations
                    (activity_id, member_id, tipo, fecha_iso, numero_confirmacion, proveedor, created_at)
                VALUES
                    (\(activityId), \(miembro.raw), \(c.tipo.rawValue), \(c.fechaISO), \(c.numeroConfirmacion), \(c.proveedor), \(Date()))
                ON CONFLICT (activity_id, member_id) DO UPDATE SET
                    tipo = EXCLUDED.tipo,
                    fecha_iso = EXCLUDED.fecha_iso,
                    numero_confirmacion = EXCLUDED.numero_confirmacion,
                    proveedor = EXCLUDED.proveedor,
                    created_at = EXCLUDED.created_at
                """, logger: self.logger)

            // 2. Marca `.reservado` en la MISMA transacción (rama por modo
            //    GUARDADO, réplica de `marcarEstado`).
            let rows = try await conn.query("""
                SELECT mode FROM itinerary_reservations
                WHERE activity_id = \(activityId) AND trip_id = \(tripId)
                """, logger: self.logger)
            var modoGuardado: String?
            for try await (m) in rows.decode(String.self) { modoGuardado = m }
            guard let modoGuardado else { return }   // no existe -> no-op (mismo criterio que memoria)

            if modoGuardado == "cada_uno" {
                _ = try await conn.query("""
                    UPDATE itinerary_reservation_members SET estado = \(EstadoReserva.reservado.rawValue)
                    WHERE activity_id = \(activityId) AND member_id = \(miembro.raw)
                    """, logger: self.logger)
            } else {
                _ = try await conn.query("""
                    UPDATE itinerary_reservations SET single_estado = \(EstadoReserva.reservado.rawValue)
                    WHERE activity_id = \(activityId) AND trip_id = \(tripId)
                    """, logger: self.logger)
            }
        }
    }

    public func confirmacion(activityId: String, en tripId: String, miembro: MiembroId) async throws -> Confirmacion? {
        let rows = try await client.query("""
            SELECT c.tipo, c.fecha_iso, c.numero_confirmacion, c.proveedor
            FROM itinerary_reservation_confirmations c
            JOIN itinerary_reservations r ON r.activity_id = c.activity_id
            WHERE c.activity_id = \(activityId) AND r.trip_id = \(tripId) AND c.member_id = \(miembro.raw)
            """, logger: logger)
        for try await (tipo, fechaISO, numeroConfirmacion, proveedor)
            in rows.decode((String, String?, String?, String?).self) {
            guard let kind = KindReserva(rawValue: tipo) else {
                throw AdaptadorReservaError.kindDesconocido(tipo)
            }
            return Confirmacion(tipo: kind, fechaISO: fechaISO, numeroConfirmacion: numeroConfirmacion, proveedor: proveedor)
        }
        return nil
    }

    // MARK: - Helpers

    private func miembrosDe(_ activityId: String) async throws -> [MiembroId: EstadoReserva] {
        let rows = try await client.query(
            "SELECT member_id, estado FROM itinerary_reservation_members WHERE activity_id = \(activityId)",
            logger: logger)
        var out: [MiembroId: EstadoReserva] = [:]
        for try await (memberId, estado) in rows.decode((String, String).self) {
            out[MiembroId(memberId)] = EstadoReserva(rawValue: estado) ?? .pendiente
        }
        return out
    }

    /// (mode, responsible_id, single_estado) a partir del `ModoReserva` de dominio.
    private static func modoASQL(_ mode: ModoReserva) -> (mode: String, responsibleId: String?, singleEstado: String?) {
        switch mode {
        case .cadaUnoElSuyo:
            return ("cada_uno", nil, nil)
        case .unoParaTodos(let responsable, let estado):
            return ("uno_para_todos", responsable?.raw, estado.rawValue)
        }
    }

    /// Reconstruye el `Reserva` de dominio desde las columnas de
    /// `itinerary_reservations` + (si `cada_uno`) los estados por miembro ya leídos.
    private static func reconstruir(
        activityId: String, tripId: String, kind: String, mode: String,
        responsibleId: String?, singleEstado: String?, estados: [MiembroId: EstadoReserva]
    ) throws -> Reserva {
        guard let kindReserva = KindReserva(rawValue: kind) else {
            throw AdaptadorReservaError.kindDesconocido(kind)
        }
        switch mode {
        case "cada_uno":
            return Reserva(activityId: activityId, tripId: tripId, kind: kindReserva,
                           mode: .cadaUnoElSuyo(estados: estados))
        case "uno_para_todos":
            let estado = EstadoReserva(rawValue: singleEstado ?? "") ?? .pendiente
            return Reserva(activityId: activityId, tripId: tripId, kind: kindReserva,
                           mode: .unoParaTodos(responsable: responsibleId.map(MiembroId.init), estado: estado))
        default:
            throw AdaptadorReservaError.modoDesconocido(mode)
        }
    }
}

/// Errores de decodificación del adaptador de reservas (columnas `kind`/`mode`
/// corruptas — no deberían darse si solo este adaptador escribe la tabla).
enum AdaptadorReservaError: Error, Equatable {
    case kindDesconocido(String)
    case modoDesconocido(String)
}
