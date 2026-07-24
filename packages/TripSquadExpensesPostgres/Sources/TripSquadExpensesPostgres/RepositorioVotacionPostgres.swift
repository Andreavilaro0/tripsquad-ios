// Adaptador Postgres de VotacionRepositorio (M4, ADR-0019 borrador —
// docs/design/votaciones-scope-y-plan.md). Mapea contra la migración 0004
// (polls + poll_votes, esta última ya existía desde 0001). Mismo patrón que
// RepositorioViajePostgres.swift: client.query con binds interpolados = seguros,
// withTransaction para `votar` (lee el estado de la poll y decide antes de
// mutar, todo en una foto consistente).
//
// `options` se guarda como jsonb (array de strings) — mismo criterio que
// `RepartoCodec` para el `split` de expenses: JSONEncoder/JSONDecoder de un
// tipo Codable simple, columna leída con `::text` y decodificada en Swift.

import Foundation
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses

/// Codec de `options` (jsonb <-> [String]). Aislado en su propio enum, igual
/// que `RepartoCodec`, para no mezclar la traducción JSON con la lógica SQL.
enum VotacionOptionsCodec {
    static func aJSON(_ options: [String]) throws -> String {
        let enc = JSONEncoder()
        return String(decoding: try enc.encode(options), as: UTF8.self)
    }

    static func desdeJSON(_ s: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(s.utf8))
    }
}

extension RepositorioPostgres: VotacionRepositorio {

    // MARK: - Crear / leer

    public func crear(_ v: Votacion) async throws {
        let optionsJSON = try VotacionOptionsCodec.aJSON(v.options)
        _ = try await client.query("""
            INSERT INTO polls (id, trip_id, question, options, created_by, created_at, closed_at)
            VALUES (\(v.id), \(v.tripId), \(v.question), \(optionsJSON)::jsonb, \(v.createdBy.raw), now(), \(v.closedAt))
            """, logger: logger)
    }

    public func votacion(id: String, en tripId: String) async throws -> Votacion? {
        let rows = try await client.query("""
            SELECT question, options::text, created_by, closed_at
            FROM polls WHERE id = \(id) AND trip_id = \(tripId)
            """, logger: logger)
        for try await (question, optionsJSON, createdBy, closedAt) in rows.decode((String, String, String, Date?).self) {
            let options = try VotacionOptionsCodec.desdeJSON(optionsJSON)
            return Votacion(id: id, tripId: tripId, question: question, options: options, createdBy: MiembroId(createdBy), closedAt: closedAt)
        }
        return nil
    }

    public func votacionesDe(_ tripId: String) async throws -> [Votacion] {
        let rows = try await client.query("""
            SELECT id, question, options::text, created_by, closed_at
            FROM polls WHERE trip_id = \(tripId) ORDER BY id
            """, logger: logger)
        var out: [Votacion] = []
        for try await (id, question, optionsJSON, createdBy, closedAt) in rows.decode((String, String, String, String, Date?).self) {
            let options = try VotacionOptionsCodec.desdeJSON(optionsJSON)
            out.append(Votacion(id: id, tripId: tripId, question: question, options: options, createdBy: MiembroId(createdBy), closedAt: closedAt))
        }
        return out
    }

    // MARK: - Votar

    /// UPSERT por `(pollId, member)` — dedupe estructural, misma PK que
    /// `poll_votes` desde 0001 (plan §2): cambiar de opción sobrescribe el
    /// voto anterior, no lo duplica. Todo en una transacción: la validación
    /// (¿existe? ¿cerrada? ¿option válida?) lee la poll en la misma foto en la
    /// que después se escribe el voto.
    public func votar(pollId: String, tripId: String, member: MiembroId, choice: String, ahora: Date) async throws -> ResultadoVotar {
        try await client.withTransaction(logger: logger) { conn in
            // FOR UPDATE OF p, t cierra el TOCTOU en AMBOS ejes (Codex P1 + bot GitHub P1):
            // bloquea la fila de la POLL y del VIAJE durante la transacción, así un cierre
            // concurrente de la poll (POST .../close) O del viaje se serializa y no puede colar
            // un voto tras el cierre. Revalidamos poll.closed_at y trip.closed_at aquí dentro.
            let rows = try await conn.query("""
                SELECT p.options::text, p.closed_at, t.closed_at
                FROM polls p JOIN trips t ON t.id = p.trip_id
                WHERE p.id = \(pollId) AND p.trip_id = \(tripId)
                FOR UPDATE OF p, t
                """, logger: self.logger)
            var options: [String]?
            var pollCerrada: Date?
            var viajeCerrado: Date?
            for try await (optionsJSON, pc, tc) in rows.decode((String, Date?, Date?).self) {
                options = try VotacionOptionsCodec.desdeJSON(optionsJSON)
                pollCerrada = pc
                viajeCerrado = tc
            }
            guard let options else { return .rechazado(razon: "poll_not_found") }
            guard viajeCerrado == nil else { return .rechazado(razon: "trip_closed") }
            guard pollCerrada == nil else { return .rechazado(razon: "poll_closed") }
            guard options.contains(choice) else { return .rechazado(razon: "invalid_option") }

            _ = try await conn.query("""
                INSERT INTO poll_votes (poll_id, member_id, choice, created_at)
                VALUES (\(pollId), \(member.raw), \(choice), \(ahora))
                ON CONFLICT (poll_id, member_id) DO UPDATE SET choice = EXCLUDED.choice, created_at = EXCLUDED.created_at
                """, logger: self.logger)
            return .registrado
        }
    }

    // MARK: - Resultado

    /// `conteo` incluye SIEMPRE todas las `options`, aunque tengan 0 votos
    /// (mismo criterio que `RepositorioEnMemoria`). `votos` en orden estable
    /// por `MiembroId` (ORDER BY member_id).
    public func resultado(pollId: String, en tripId: String) async throws -> ResultadoVotacion? {
        guard let votacion = try await votacion(id: pollId, en: tripId) else { return nil }

        // JOIN polls + p.trip_id (Codex P2, defensa): aunque poll_id es PK global y ya se
        // validó `votacion(id,en:)`, se filtra explícito por trip_id para no cruzar viajes.
        let rows = try await client.query("""
            SELECT pv.member_id, pv.choice FROM poll_votes pv
            JOIN polls p ON p.id = pv.poll_id
            WHERE pv.poll_id = \(pollId) AND p.trip_id = \(tripId)
            ORDER BY pv.member_id
            """, logger: logger)
        var conteo = Dictionary(uniqueKeysWithValues: votacion.options.map { ($0, 0) })
        var votos: [(MiembroId, String)] = []
        for try await (memberId, choice) in rows.decode((String, String).self) {
            conteo[choice, default: 0] += 1
            votos.append((MiembroId(memberId), choice))
        }
        return ResultadoVotacion(votacion: votacion, conteo: conteo, votos: votos)
    }

    // MARK: - Cerrar

    /// Idempotente (igual que `RepositorioEnMemoria.cerrar`): si el poll no
    /// existe en ese tripId, la UPDATE afecta 0 filas y no pasa nada.
    public func cerrar(pollId: String, en tripId: String, ahora: Date) async throws {
        _ = try await client.query(
            "UPDATE polls SET closed_at = \(ahora) WHERE id = \(pollId) AND trip_id = \(tripId)",
            logger: logger)
    }
}
