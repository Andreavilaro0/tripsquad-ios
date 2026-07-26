// Adaptador Postgres del repositorio de gastos. Implementa los puertos de
// TripSquadExpenses contra el esquema de db/migrations. PostgresNIO (API traída via
// Context7): PostgresClient + withTransaction (BEGIN/COMMIT automático).
//
// Garantías replicadas del adaptador en memoria (misma spec):
//   - idempotencia por (user_id, idempotency_key) con respuesta congelada
//   - dedupe estructural por id (ON CONFLICT DO NOTHING), tombstones incluidos
//   - conflicto por ETag (If-Match), tombstone en el borrado

import Foundation
import Logging
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses

public struct RepositorioPostgres: GastoRepositorio, Membresia {
    let client: PostgresClient
    let logger: Logger

    public init(client: PostgresClient, logger: Logger = Logger(label: "expenses.postgres")) {
        self.client = client
        self.logger = logger
    }

    // MARK: - Membresia

    public func esMiembro(_ miembro: MiembroId, de tripId: String) async throws -> Bool {
        let rows = try await client.query(
            "SELECT 1 FROM trip_members WHERE trip_id = \(tripId) AND member_id = \(miembro.raw) AND left_at IS NULL",
            logger: logger)
        for try await _ in rows { return true }
        return false
    }

    public func viajeCerrado(_ tripId: String) async throws -> Bool {
        let rows = try await client.query(
            "SELECT closed_at FROM trips WHERE id = \(tripId)", logger: logger)
        for try await (closedAt) in rows.decode(Date?.self) { return closedAt != nil }
        return false
    }

    // MARK: - Replay

    public func respuestaPrevia(actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura? {
        let rows = try await client.query(
            "SELECT response_body FROM idempotency_keys WHERE user_id = \(actor.raw) AND idempotency_key = \(idempotencyKey) AND response_body IS NOT NULL",
            logger: logger)
        for try await (body) in rows.decode(String.self) {
            if let s = RespuestaSerializada.desde(body) { return s.comoReplay }
        }
        return nil
    }

    // MARK: - Crear

    public func guardar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura {
        let (kind, splitJSON, shares) = try RepartoCodec.aSQL(gasto.reparto)
        let etag = UUID().uuidString

        return try await client.withTransaction(logger: logger) { conn in
            // Reclamar la clave ANTES de mutar (hallazgo P1 de Codex): dos peticiones
            // concurrentes con la misma (actor,key) se serializan en el índice único;
            // la perdedora ve el replay tras el commit de la ganadora.
            switch try await self.reclamar(conn, actor: actor, key: idempotencyKey) {
            case .replay(let r): return r
            case .enVuelo: return .rechazado(razon: "in_flight")
            case .duena: break
            }

            // Dedupe estructural: el id de cliente es la PK. ON CONFLICT DO NOTHING
            // hace el duplicado físicamente imposible (ADR-0012 §2).
            let ins = try await conn.query("""
                INSERT INTO expenses (id, trip_id, paid_by, amount_reference, amount_original,
                    currency_original, split_kind, split, etag)
                VALUES (\(gasto.id), \(tripId), \(gasto.pagadoPor.raw), \(gasto.importeMinor),
                    \(gasto.importeMinor), 'EUR', \(kind), \(splitJSON)::jsonb, \(etag))
                ON CONFLICT (id) DO NOTHING
                RETURNING etag
                """, logger: self.logger)

            var creado = false
            for try await _ in ins.decode(String.self) { creado = true }

            let resultado: ResultadoEscritura
            if creado {
                if let shares { try await self.insertarShares(conn, expenseId: gasto.id, shares: shares) }
                resultado = .creado(etag: etag)
            } else {
                // El id ya existe: ¿está tombstoneado? -> no resucita (ADR-0013 §5).
                resultado = try await self.estadoDeExistente(conn, id: gasto.id, tripId: tripId)
            }
            try await self.congelar(conn, actor: actor, key: idempotencyKey, resultado: resultado)
            return resultado
        }
    }

    // MARK: - Editar

    public func actualizar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura {
        let (kind, splitJSON, shares) = try RepartoCodec.aSQL(gasto.reparto)
        let nuevoEtag = UUID().uuidString

        return try await client.withTransaction(logger: logger) { conn in
            switch try await self.reclamar(conn, actor: actor, key: idempotencyKey) {
            case .replay(let r): return r
            case .enVuelo: return .rechazado(razon: "in_flight")
            case .duena: break
            }

            // UPDATE condicional ATÓMICO (hallazgo P1 de Codex): el ETag va en el
            // WHERE, así dos ediciones concurrentes con el mismo If-Match no se pisan
            // — solo una encuentra la fila con ese etag; la otra afecta 0 filas.
            let upd = try await conn.query("""
                UPDATE expenses SET paid_by = \(gasto.pagadoPor.raw), amount_reference = \(gasto.importeMinor),
                    split_kind = \(kind), split = \(splitJSON)::jsonb, etag = \(nuevoEtag), updated_at = now()
                WHERE id = \(gasto.id) AND trip_id = \(tripId) AND etag = \(etag) AND deleted_at IS NULL
                RETURNING etag
                """, logger: self.logger)
            var actualizado = false
            for try await _ in upd.decode(String.self) { actualizado = true }

            guard actualizado else {
                // 0 filas: o no existe/borrado (not_found) o el etag no coincide
                // (conflicto). Distinguimos leyendo el estado actual.
                if let actual = try await self.etagActual(conn, id: gasto.id, tripId: tripId) {
                    return .conflicto(serverEtag: actual)   // no se congela: no terminal
                }
                let r = ResultadoEscritura.rechazado(razon: "not_found")
                try await self.congelar(conn, actor: actor, key: idempotencyKey, resultado: r)
                return r
            }

            // edited_by = actor -> historial append-only (ADR-0015 §15).
            _ = try await conn.query("""
                INSERT INTO expense_revisions (expense_id, edited_by, field, new_value)
                VALUES (\(gasto.id), \(actor.raw), 'expense', \(splitJSON)::jsonb)
                """, logger: self.logger)
            // Las shares se limpian SIEMPRE al editar (hallazgo P2 de Codex): si el
            // reparto pasa de exacto a igual/peso, no deben quedar shares rancias.
            _ = try await conn.query("DELETE FROM expense_shares WHERE expense_id = \(gasto.id)", logger: self.logger)
            if let shares { try await self.insertarShares(conn, expenseId: gasto.id, shares: shares) }

            let r = ResultadoEscritura.actualizado(etag: nuevoEtag)
            try await self.congelar(conn, actor: actor, key: idempotencyKey, resultado: r)
            return r
        }
    }

    // MARK: - Eliminar

    public func eliminar(id: String, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura {
        return try await client.withTransaction(logger: logger) { conn in
            switch try await self.reclamar(conn, actor: actor, key: idempotencyKey) {
            case .replay(let r): return r
            case .enVuelo: return .rechazado(razon: "in_flight")
            case .duena: break
            }

            // Borrado condicional ATÓMICO por etag: no es ciego ante ediciones
            // concurrentes (ADR-0013 §2). El tombstone se marca con deleted_at.
            let del = try await conn.query("""
                UPDATE expenses SET deleted_at = now()
                WHERE id = \(id) AND trip_id = \(tripId) AND etag = \(etag) AND deleted_at IS NULL
                RETURNING etag
                """, logger: self.logger)
            var borrado = false
            for try await _ in del.decode(String.self) { borrado = true }

            if !borrado {
                // 0 filas: o ya no existe/borrado (idempotencia del DELETE -> eliminado)
                // o el etag no coincide (conflicto).
                if let actual = try await self.etagActual(conn, id: id, tripId: tripId) {
                    return .conflicto(serverEtag: actual)
                }
            }
            let r = ResultadoEscritura.eliminado
            try await self.congelar(conn, actor: actor, key: idempotencyKey, resultado: r)
            return r
        }
    }

    // MARK: - Lecturas

    public func gastos(de tripId: String) async throws -> [GastoConEtag] {
        let rows = try await client.query("""
            SELECT id, paid_by, amount_reference, split_kind, split::text, etag
            FROM expenses WHERE trip_id = \(tripId) AND deleted_at IS NULL ORDER BY id
            """, logger: logger)
        var out: [GastoConEtag] = []
        for try await (id, paidBy, amount, kind, split, etag) in rows.decode((String, String, Int64, String, String, String).self) {
            let shares = kind == "exact" ? try await leerShares(id: id) : []
            let reparto = try RepartoCodec.desdeSQL(kind: kind, json: split, shares: shares)
            let gasto = Gasto(id: id, pagadoPor: MiembroId(paidBy), importeMinor: amount, reparto: reparto)
            out.append(GastoConEtag(gasto: gasto, etag: etag))
        }
        return out
    }

    public func gasto(id: String, en tripId: String) async throws -> GastoConEtag? {
        try await gastos(de: tripId).first { $0.gasto.id == id }
    }

    // MARK: - Helpers (dentro de la conexión de la transacción)

    /// Resultado de reclamar la clave de idempotencia (patrón Brandur, ADR-0012 §2).
    enum Reclamacion { case duena, enVuelo, replay(ResultadoEscritura) }

    /// Intenta reclamar la clave. Si ya tiene respuesta congelada -> replay. Si la
    /// fila existe pero sin respuesta -> en vuelo (otra petición la tiene). Si no
    /// existía -> la reclamamos e insertamos (`.duena`). El `INSERT ON CONFLICT DO
    /// NOTHING` se serializa contra inserciones concurrentes del mismo par en el
    /// índice único: la perdedora bloquea hasta el commit de la ganadora y luego ve
    /// la respuesta congelada.
    private func reclamar(_ conn: PostgresConnection, actor: MiembroId, key: String) async throws -> Reclamacion {
        if let previa = try await replayEn(conn, actor: actor, key: key) { return .replay(previa) }
        let ins = try await conn.query("""
            INSERT INTO idempotency_keys (user_id, idempotency_key, request_hash, first_sent, locked_at)
            VALUES (\(actor.raw), \(key), '', now(), now())
            ON CONFLICT (user_id, idempotency_key) DO NOTHING
            RETURNING user_id
            """, logger: logger)
        for try await _ in ins.decode(String.self) { return .duena }
        // No reclamamos: la fila ya existía. Tras el bloqueo, la respuesta ya debería
        // estar congelada.
        if let previa = try await replayEn(conn, actor: actor, key: key) { return .replay(previa) }
        return .enVuelo
    }

    private func replayEn(_ conn: PostgresConnection, actor: MiembroId, key: String) async throws -> ResultadoEscritura? {
        let rows = try await conn.query(
            "SELECT response_body FROM idempotency_keys WHERE user_id = \(actor.raw) AND idempotency_key = \(key) AND response_body IS NOT NULL",
            logger: logger)
        for try await (body) in rows.decode(String.self) {
            if let s = RespuestaSerializada.desde(body) { return s.comoReplay }
        }
        return nil
    }

    /// Congela la respuesta en la fila de idempotencia ya reclamada (UPDATE, no
    /// INSERT: la fila existe desde `reclamar`). No se congela el conflicto: no es
    /// terminal.
    private func congelar(_ conn: PostgresConnection, actor: MiembroId, key: String, resultado: ResultadoEscritura) async throws {
        if case .conflicto = resultado { return }
        let body = RespuestaSerializada(resultado).json
        _ = try await conn.query("""
            UPDATE idempotency_keys SET response_body = \(body)::jsonb, locked_at = NULL
            WHERE user_id = \(actor.raw) AND idempotency_key = \(key)
            """, logger: logger)
    }

    private func etagActual(_ conn: PostgresConnection, id: String, tripId: String) async throws -> String? {
        let rows = try await conn.query(
            "SELECT etag FROM expenses WHERE id = \(id) AND trip_id = \(tripId) AND deleted_at IS NULL",
            logger: logger)
        for try await (e) in rows.decode(String.self) { return e }
        return nil
    }

    /// FUGA ENTRE VIAJES (P1 de la revisión integrada): esta consulta recibía `tripId`
    /// y NO lo usaba. Como `expenses.id` es PK GLOBAL y lo elige el CLIENTE, el
    /// `ON CONFLICT (id)` de `guardar` puede haber chocado con un gasto de OTRO viaje;
    /// sin el filtro, se devolvía el `etag` y el estado de borrado de ese gasto ajeno
    /// como si fuera del viaje del actor. Con el filtro, "no hay fila en ESTE viaje"
    /// significa "el id está ocupado fuera": rechazo permanente y OPACO (`id_conflict`),
    /// que no revela nada del otro viaje.
    ///
    /// Nota: antes del filtro, la rama `not_found` era inalcanzable — si el ON CONFLICT
    /// no insertó, la fila existía necesariamente. Ahora esa rama es justo el caso de
    /// colisión cruzada, y por eso cambia de razón.
    private func estadoDeExistente(_ conn: PostgresConnection, id: String, tripId: String) async throws -> ResultadoEscritura {
        let rows = try await conn.query(
            "SELECT etag, deleted_at FROM expenses WHERE id = \(id) AND trip_id = \(tripId)", logger: logger)
        for try await (etag, deletedAt) in rows.decode((String, Date?).self) {
            return deletedAt != nil ? .rechazado(razon: "deleted") : .reproducido(etag: etag)
        }
        return .rechazado(razon: "id_conflict")
    }

    private func insertarShares(_ conn: PostgresConnection, expenseId: String, shares: [(String, Int64)]) async throws {
        for (member, amount) in shares {
            _ = try await conn.query("""
                INSERT INTO expense_shares (expense_id, member_id, amount_minor)
                VALUES (\(expenseId), \(member), \(amount))
                ON CONFLICT (expense_id, member_id) DO UPDATE SET amount_minor = EXCLUDED.amount_minor
                """, logger: logger)
        }
    }

    func leerShares(id: String) async throws -> [(String, Int64)] {
        let rows = try await client.query(
            "SELECT member_id, amount_minor FROM expense_shares WHERE expense_id = \(id)", logger: logger)
        var out: [(String, Int64)] = []
        for try await (m, a) in rows.decode((String, Int64).self) { out.append((m, a)) }
        return out
    }
}

// MARK: - SettlementRepositorio

extension RepositorioPostgres: SettlementRepositorio {
    /// Dedupe estructural (ADR-0015 §5, ADR-0017): la clave natural es
    /// `(trip_id, settlement_id, from_member, to_member, transfer_index)` — la UNIQUE
    /// de `settlements` — NO el `id` (que ahora es un surrogate UUID de cliente). La
    /// primera vez crea con `status='pending'`; los reintentos con la misma clave
    /// natural son `duplicado` (ON CONFLICT DO NOTHING, no error) y devuelven el id ya
    /// existente. `round` no se pasa: tiene default 0 desde la migración 0002.
    public func crear(_ s: Settlement) async throws -> ResultadoSettle {
        let id = UUID().uuidString
        let ins = try await client.query("""
            INSERT INTO settlements
                (id, trip_id, settlement_id, from_member, to_member, transfer_index, amount_minor, status, created_by, expires_at)
            VALUES (\(id), \(s.tripId), \(s.settlementId), \(s.from.raw), \(s.to.raw), \(s.transferIndex),
                    \(s.amountMinor), 'pending', \(s.createdBy.raw), \(s.expiresAt))
            ON CONFLICT (trip_id, settlement_id, from_member, to_member, transfer_index) DO NOTHING
            RETURNING id
            """, logger: logger)
        for try await (nuevoId) in ins.decode(String.self) { return .creado(id: nuevoId) }
        // Choque: leer el id existente por la clave natural.
        let sel = try await client.query("""
            SELECT id FROM settlements
            WHERE trip_id = \(s.tripId) AND settlement_id = \(s.settlementId)
              AND from_member = \(s.from.raw) AND to_member = \(s.to.raw) AND transfer_index = \(s.transferIndex)
            """, logger: logger)
        for try await (existente) in sel.decode(String.self) { return .duplicado(id: existente) }
        // El ON CONFLICT no insertó pero la fila en conflicto ya no está (borrada en la
        // carrera). NO devolvemos un id huérfano (Gemini P1): es un estado inconsistente.
        throw SettlementInconsistente(tripId: s.tripId, settlementId: s.settlementId)
    }

    public func settlement(id: String, en tripId: String) async throws -> Settlement? {
        let rows = try await client.query("""
            SELECT settlement_id, from_member, to_member, transfer_index, amount_minor, created_by,
                   expires_at, status, resolved_by, resolved_at, reject_reason
            FROM settlements WHERE id = \(id) AND trip_id = \(tripId)
            """, logger: logger)
        for try await (sid, fromM, toM, idx, amount, createdBy, expires, status, rBy, rAt, reason)
            in rows.decode((String, String, String, Int, Int64, String, Date, String, String?, Date?, String?).self) {
            // fail-safe (Kimi P2): un status corrupto en BD NO debe ser confirmable → .cancelled.
            return Settlement(settlementId: sid, tripId: tripId, from: MiembroId(fromM), to: MiembroId(toM),
                              transferIndex: idx, amountMinor: amount, createdBy: MiembroId(createdBy),
                              expiresAt: expires, status: EstadoSettlement(rawValue: status) ?? .cancelled,
                              resolvedBy: rBy.map(MiembroId.init), resolvedAt: rAt, rejectReason: reason)
        }
        return nil
    }

    /// UPDATE condicional atómico: solo transiciona si sigue `pending` y no ha
    /// caducado (mismo patrón que el ETag condicional de `actualizar` en gastos). La
    /// autorización de QUIÉN puede transicionar vive en el caso de uso, no aquí.
    public func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement,
                             por actor: MiembroId, ahora: Date, rejectReason: String?) async throws -> ResultadoTransicion {
        let rows = try await client.query("""
            UPDATE settlements
            SET status = \(nuevo.rawValue), resolved_by = \(actor.raw), resolved_at = \(ahora), reject_reason = \(rejectReason)
            WHERE id = \(id) AND trip_id = \(tripId) AND status = 'pending' AND expires_at >= \(ahora)
            RETURNING id
            """, logger: logger)
        for try await _ in rows.decode(String.self) { return .ok }
        // No actualizó ninguna fila: distinguir por qué (no existe / caducado / ya resuelto).
        guard let s = try await settlement(id: id, en: tripId) else { return .noEncontrado }
        if s.status == .pending && s.expiresAt < ahora { return .caducado }
        return .estadoInvalido
    }

    /// SIN `LIMIT` a propósito: es la entrada de `balancesConLiquidaciones`, no una
    /// página. Truncarla dejaría pagos fuera del cálculo y corrompería los saldos
    /// (ver `SettlementRepositorio.confirmados`). Sí lleva orden estable.
    public func confirmados(de tripId: String) async throws -> [Settlement] {
        try await filasPorEstado(tripId, "confirmed", limit: nil, noCaducadosDesde: nil).map { $0.1 }
    }

    /// Pendientes CON id (Task 4): la lista HTTP necesita el id para confirmar/rechazar/cancelar.
    /// Excluye los caducados EN SQL, antes del `LIMIT`, para que no consuman la página.
    public func pendientes(de tripId: String, limit: Int, ahora: Date) async throws -> [(String, Settlement)] {
        try await filasPorEstado(tripId, "pending", limit: limit, noCaducadosDesde: ahora)
    }

    /// Barrido de caducidad (bead 1ea): materializa como `cancelled` los `pending`
    /// vencidos de TODOS los viajes. `resolved_by` queda NULL (lo caduca el sistema, no
    /// un actor). Cuenta las filas por el `RETURNING id`. Idempotente: una 2ª pasada no
    /// encuentra ya pending vencidos. El índice parcial `idx_settlements_expires_at`
    /// (WHERE status='pending') sirve exactamente este filtro.
    public func caducarPendientes(ahora: Date) async throws -> Int {
        let rows = try await client.query("""
            UPDATE settlements SET status = 'cancelled', resolved_at = \(ahora)
            WHERE status = 'pending' AND expires_at < \(ahora)
            RETURNING id
            """, logger: logger)
        var n = 0
        for try await _ in rows.decode(String.self) { n += 1 }
        return n
    }

    /// UNA sola query por estado (Gemini P1: antes era N+1 — un SELECT de ids + un SELECT
    /// por fila). Selecciona todas las columnas y decodifica el array completo.
    ///
    /// `ORDER BY created_at, id`: antes no ordenaba NADA, así que Postgres devolvía el
    /// orden físico del heap (cambia con cada UPDATE) mientras el repo en memoria hacía
    /// otra cosa — dos "listas" distintas para el mismo dato. `created_at` solo no basta
    /// (dos pagos del mismo lote comparten `now()`), de ahí el `id` de desempate. El
    /// índice `idx_settlements_trip_status (trip_id, status)` sigue sirviendo el filtro.
    ///
    /// `limit == nil` -> `LIMIT NULL`, que en Postgres es exactamente "sin límite"
    /// (equivale a omitir la cláusula). Así una sola query cubre el listado paginado y
    /// la lectura completa de saldos, sin duplicar el SELECT.
    /// `noCaducadosDesde`: si viene, añade `AND expires_at >= $ahora` — se filtra la
    /// caducidad ANTES del `LIMIT` (solo aplica a pending; `confirmed` pasa `nil`). Un
    /// `nil` no toca la query. `PostgresQuery` interpola binds, así que el `IS NULL`
    /// del bind opcional NO sirve para "sin filtro" — hay que ramificar el SQL.
    private func filasPorEstado(_ tripId: String, _ status: String, limit: Int?, noCaducadosDesde ahora: Date?) async throws -> [(String, Settlement)] {
        let rows: PostgresRowSequence
        if let ahora {
            rows = try await client.query("""
                SELECT id, settlement_id, from_member, to_member, transfer_index, amount_minor, created_by,
                       expires_at, status, resolved_by, resolved_at, reject_reason
                FROM settlements WHERE trip_id = \(tripId) AND status = \(status) AND expires_at >= \(ahora)
                ORDER BY created_at, id
                LIMIT \(limit)
                """, logger: logger)
        } else {
            rows = try await client.query("""
                SELECT id, settlement_id, from_member, to_member, transfer_index, amount_minor, created_by,
                       expires_at, status, resolved_by, resolved_at, reject_reason
                FROM settlements WHERE trip_id = \(tripId) AND status = \(status)
                ORDER BY created_at, id
                LIMIT \(limit)
                """, logger: logger)
        }
        var out: [(String, Settlement)] = []
        for try await (id, sid, fromM, toM, idx, amount, createdBy, expires, st, rBy, rAt, reason)
            in rows.decode((String, String, String, String, Int, Int64, String, Date, String, String?, Date?, String?).self) {
            out.append((id, Settlement(settlementId: sid, tripId: tripId, from: MiembroId(fromM), to: MiembroId(toM),
                                       transferIndex: idx, amountMinor: amount, createdBy: MiembroId(createdBy),
                                       expiresAt: expires, status: EstadoSettlement(rawValue: st) ?? .cancelled,
                                       resolvedBy: rBy.map(MiembroId.init), resolvedAt: rAt, rejectReason: reason)))
        }
        return out
    }
}

/// Estado inconsistente al crear un settlement: el ON CONFLICT no insertó pero la fila en
/// conflicto ya no existe (carrera con un borrado). Ver `crear` (Gemini P1).
struct SettlementInconsistente: Error {
    let tripId: String
    let settlementId: String
}
