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

    private func estadoDeExistente(_ conn: PostgresConnection, id: String, tripId: String) async throws -> ResultadoEscritura {
        let rows = try await conn.query(
            "SELECT etag, deleted_at FROM expenses WHERE id = \(id)", logger: logger)
        for try await (etag, deletedAt) in rows.decode((String, Date?).self) {
            return deletedAt != nil ? .rechazado(razon: "deleted") : .reproducido(etag: etag)
        }
        return .rechazado(razon: "not_found")
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
    /// Dedupe estructural (ADR-0015 §5): la primera vez registra; los reintentos con
    /// la misma clave son `duplicado` (idempotente, no error).
    public func registrar(_ settlement: Settlement) async throws -> ResultadoSettle {
        let clave = settlement.idDeterminista
        let ins = try await client.query("""
            INSERT INTO settlements (settlement_id, trip_id, from_id, to_id, transfer_index, amount_minor)
            VALUES (\(settlement.settlementId), \(settlement.tripId), \(settlement.from.raw), \(settlement.to.raw), \(settlement.transferIndex), \(settlement.amountMinor))
            ON CONFLICT (settlement_id) DO NOTHING
            RETURNING settlement_id
            """, logger: logger)
        for try await _ in ins.decode(String.self) { return .registrado }
        return .duplicado
    }
}
