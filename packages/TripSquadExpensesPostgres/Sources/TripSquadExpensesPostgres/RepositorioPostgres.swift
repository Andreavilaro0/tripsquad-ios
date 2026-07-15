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
            if let previa = try await self.replayEn(conn, actor: actor, key: idempotencyKey) { return previa }

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
            if let previa = try await self.replayEn(conn, actor: actor, key: idempotencyKey) { return previa }

            guard let actual = try await self.etagActual(conn, id: gasto.id, tripId: tripId) else {
                let r = ResultadoEscritura.rechazado(razon: "not_found")
                try await self.congelar(conn, actor: actor, key: idempotencyKey, resultado: r)
                return r
            }
            // El árbitro del conflicto es el ETag (ADR-0013 §2). El conflicto NO se
            // congela: no es terminal (el cliente resuelve y reintenta).
            guard actual == etag else { return .conflicto(serverEtag: actual) }

            _ = try await conn.query("""
                UPDATE expenses SET paid_by = \(gasto.pagadoPor.raw), amount_reference = \(gasto.importeMinor),
                    split_kind = \(kind), split = \(splitJSON)::jsonb, etag = \(nuevoEtag), updated_at = now()
                WHERE id = \(gasto.id)
                """, logger: self.logger)
            // edited_by = actor -> historial append-only (ADR-0015 §15).
            _ = try await conn.query("""
                INSERT INTO expense_revisions (expense_id, edited_by, field, new_value)
                VALUES (\(gasto.id), \(actor.raw), 'expense', \(splitJSON)::jsonb)
                """, logger: self.logger)
            if let shares {
                _ = try await conn.query("DELETE FROM expense_shares WHERE expense_id = \(gasto.id)", logger: self.logger)
                try await self.insertarShares(conn, expenseId: gasto.id, shares: shares)
            }
            let r = ResultadoEscritura.actualizado(etag: nuevoEtag)
            try await self.congelar(conn, actor: actor, key: idempotencyKey, resultado: r)
            return r
        }
    }

    // MARK: - Eliminar

    public func eliminar(id: String, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura {
        return try await client.withTransaction(logger: logger) { conn in
            if let previa = try await self.replayEn(conn, actor: actor, key: idempotencyKey) { return previa }

            guard let actual = try await self.etagActual(conn, id: id, tripId: tripId) else {
                // Ya no existe o ya está tombstoneado: reintento de un borrado hecho
                // no es error (idempotencia del DELETE, ADR-0013 §2).
                let r = ResultadoEscritura.eliminado
                try await self.congelar(conn, actor: actor, key: idempotencyKey, resultado: r)
                return r
            }
            guard actual == etag else { return .conflicto(serverEtag: actual) }

            _ = try await conn.query("UPDATE expenses SET deleted_at = now() WHERE id = \(id)", logger: self.logger)
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

    private func replayEn(_ conn: PostgresConnection, actor: MiembroId, key: String) async throws -> ResultadoEscritura? {
        let rows = try await conn.query(
            "SELECT response_body FROM idempotency_keys WHERE user_id = \(actor.raw) AND idempotency_key = \(key) AND response_body IS NOT NULL",
            logger: logger)
        for try await (body) in rows.decode(String.self) {
            if let s = RespuestaSerializada.desde(body) { return s.comoReplay }
        }
        return nil
    }

    private func congelar(_ conn: PostgresConnection, actor: MiembroId, key: String, resultado: ResultadoEscritura) async throws {
        // No se congela el conflicto: no es terminal.
        if case .conflicto = resultado { return }
        let body = RespuestaSerializada(resultado).json
        _ = try await conn.query("""
            INSERT INTO idempotency_keys (user_id, idempotency_key, request_hash, first_sent, response_body)
            VALUES (\(actor.raw), \(key), '', now(), \(body)::jsonb)
            ON CONFLICT (user_id, idempotency_key) DO UPDATE SET response_body = EXCLUDED.response_body
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

    private func leerShares(id: String) async throws -> [(String, Int64)] {
        let rows = try await client.query(
            "SELECT member_id, amount_minor FROM expense_shares WHERE expense_id = \(id)", logger: logger)
        var out: [(String, Int64)] = []
        for try await (m, a) in rows.decode((String, Int64).self) { out.append((m, a)) }
        return out
    }
}
