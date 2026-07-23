import Foundation
import TripSquadDomain

public struct ComandoCrearPago: Sendable {
    public let tripId: String
    public let settlementId: String
    public let from: MiembroId
    public let to: MiembroId
    public let transferIndex: Int
    public let amountMinor: Int64
    public let actor: MiembroId
    public init(tripId: String, settlementId: String, from: MiembroId, to: MiembroId,
                transferIndex: Int, amountMinor: Int64, actor: MiembroId) {
        self.tripId = tripId; self.settlementId = settlementId; self.from = from; self.to = to
        self.transferIndex = transferIndex; self.amountMinor = amountMinor; self.actor = actor
    }
}

/// Casos de uso de `:settle` (ADR-0016/0017). Sugerir es lectura pura; crear/confirmar/
/// rechazar/cancelar son la máquina de estados de la afirmación de pago.
public struct CasosDeUsoSettle: Sendable {
    private let repo: SettlementRepositorio
    private let membresia: Membresia
    public init(repo: SettlementRepositorio, membresia: Membresia) {
        self.repo = repo; self.membresia = membresia
    }

    /// Concepto (a): sugiere las transferencias que dejan los saldos a cero. Pura.
    public func sugerir(saldos: [MiembroId: Int64]) -> [Transferencia] {
        liquidar(saldos)
    }

    /// Autorización de la sugerencia (finding D de la revisión multi-modelo): debe
    /// comprobarse ANTES de leer gastos, para no filtrar lectura de un viaje ajeno ni
    /// devolver 5xx (si la BD falla al leer gastos) en vez del 403 que exige la invariante.
    public func puedeSugerir(tripId: String, actor: MiembroId) async throws -> Bool {
        try await membresia.esMiembro(actor, de: tripId)
    }

    private static let ttl: TimeInterval = 30 * 24 * 3600   // 30 días (ADR-0017)

    /// Crea afirmaciones en lote (ADR-0017). Valida por item; un item inválido no tumba el
    /// resto. `actor` debe ser parte del pago y `from`/`to` miembros del viaje (fix C).
    public func crearPagos(_ cmds: [ComandoCrearPago], ahora: Date) async throws -> [ResultadoSettle] {
        var out: [ResultadoSettle] = []
        for c in cmds {
            out.append(try await crearUno(c, ahora: ahora))
        }
        return out
    }

    private func crearUno(_ c: ComandoCrearPago, ahora: Date) async throws -> ResultadoSettle {
        guard c.actor == c.from || c.actor == c.to else { return .rechazado(razon: "actor_not_party") }
        guard c.from != c.to else { return .rechazado(razon: "self_payment") }   // no autopagos (Gemini P3)
        guard try await membresia.esMiembro(c.from, de: c.tripId),
              try await membresia.esMiembro(c.to, de: c.tripId) else { return .rechazado(razon: "payee_not_member") }
        if try await membresia.viajeCerrado(c.tripId) { return .rechazado(razon: "trip_closed") }
        guard c.amountMinor > 0 else { return .rechazado(razon: "invalid_amount") }
        let s = Settlement(settlementId: c.settlementId, tripId: c.tripId, from: c.from, to: c.to,
                           transferIndex: c.transferIndex, amountMinor: c.amountMinor,
                           createdBy: c.actor, expiresAt: ahora.addingTimeInterval(Self.ttl))
        return try await repo.crear(s)
    }

    public func confirmar(id: String, en tripId: String, por actor: MiembroId, ahora: Date) async throws -> ResultadoTransicion {
        try await transicion(id: id, en: tripId, a: .confirmed, por: actor, ahora: ahora, esCreador: false, motivo: nil)
    }
    public func rechazar(id: String, en tripId: String, por actor: MiembroId, ahora: Date, motivo: String?) async throws -> ResultadoTransicion {
        try await transicion(id: id, en: tripId, a: .rejected, por: actor, ahora: ahora, esCreador: false, motivo: motivo)
    }
    public func cancelar(id: String, en tripId: String, por actor: MiembroId, ahora: Date) async throws -> ResultadoTransicion {
        try await transicion(id: id, en: tripId, a: .cancelled, por: actor, ahora: ahora, esCreador: true, motivo: nil)
    }

    /// Lista de pendientes NO caducados, CON su id de almacenamiento (Task 4: la ruta HTTP
    /// la necesita para confirmar/rechazar/cancelar los ítems). Excluye los vencidos
    /// (`expiresAt < ahora`): un pending caducado ya no se puede confirmar, así que no debe
    /// listarse ni marcarse como activo (Codex P3). Delega en el repo.
    public func pendientes(tripId: String, ahora: Date) async throws -> [(String, Settlement)] {
        try await repo.pendientes(de: tripId).filter { $0.1.expiresAt >= ahora }
    }

    /// Pagos CONFIRMADOS del viaje (ADR-0017): los únicos que descuentan saldo (Task 5).
    public func confirmados(tripId: String) async throws -> [Settlement] {
        try await repo.confirmados(de: tripId)
    }

    /// Autoriza según quién puede: confirm/reject → la CONTRAPARTE (parte ≠ createdBy);
    /// cancel → el CREADOR. Luego delega la aplicación (sobre pending no caducado) al repo.
    private func transicion(id: String, en tripId: String, a nuevo: EstadoSettlement,
                            por actor: MiembroId, ahora: Date, esCreador: Bool, motivo: String?) async throws -> ResultadoTransicion {
        // Membresía ACTUAL primero (Codex P2 / ADR-0014 + Kimi P2): así un no-miembro recibe
        // 403 exista o no el settlement (no filtra su existencia), y un expulsado con JWT
        // aún válido no puede seguir operando sobre sus settlements.
        guard try await membresia.esMiembro(actor, de: tripId) else { return .noAutorizado }
        guard let s = try await repo.settlement(id: id, en: tripId) else { return .noEncontrado }
        // Guardia defensiva (Codex P2): `createdBy` siempre es parte en filas creadas por
        // este código; si no lo fuera (fila legacy/corrupta), no es autorizable por nadie.
        guard s.createdBy == s.from || s.createdBy == s.to else { return .noAutorizado }
        let contraparte = (s.createdBy == s.from) ? s.to : s.from
        let autorizado = esCreador ? (actor == s.createdBy) : (actor == contraparte)
        guard autorizado else { return .noAutorizado }
        return try await repo.transicionar(id: id, en: tripId, a: nuevo, por: actor, ahora: ahora, rejectReason: motivo)
    }
}
