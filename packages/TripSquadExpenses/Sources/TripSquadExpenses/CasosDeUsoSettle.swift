import TripSquadDomain

public struct ComandoRegistrarPago: Sendable {
    public let tripId: String
    public let settlementId: String
    public let from: MiembroId
    public let to: MiembroId
    public let transferIndex: Int
    public let amountMinor: Int64
    public let actor: MiembroId
    public init(tripId: String, settlementId: String, from: MiembroId, to: MiembroId, transferIndex: Int, amountMinor: Int64, actor: MiembroId) {
        self.tripId = tripId; self.settlementId = settlementId
        self.from = from; self.to = to
        self.transferIndex = transferIndex; self.amountMinor = amountMinor; self.actor = actor
    }
}

/// Casos de uso de `:settle` (ADR-0016). Sugerir es lectura pura; registrar es la
/// escritura idempotente de un pago real.
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

    /// Concepto (c): registra un pago real. Idempotente por settlementId.
    public func registrarPago(_ c: ComandoRegistrarPago) async throws -> ResultadoSettle {
        guard try await membresia.esMiembro(c.actor, de: c.tripId) else { return .rechazado(razon: "not_member") }
        if try await membresia.viajeCerrado(c.tripId) { return .rechazado(razon: "trip_closed") }
        guard c.amountMinor > 0 else { return .rechazado(razon: "invalid_amount") }
        let s = Settlement(settlementId: c.settlementId, tripId: c.tripId, from: c.from, to: c.to, transferIndex: c.transferIndex, amountMinor: c.amountMinor)
        return try await repo.registrar(s)
    }
}
