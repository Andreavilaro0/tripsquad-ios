import TripSquadDomain

/// Un pago real registrado entre dos miembros (ADR-0016 concepto c). Append-only:
/// no borra deudas, es una entrada nueva que el cálculo de saldos incorpora.
public struct Settlement: Equatable, Sendable {
    public let settlementId: String   // generado en cliente; ancla de idempotencia
    public let tripId: String
    public let from: MiembroId
    public let to: MiembroId
    public let transferIndex: Int
    public let amountMinor: Int64
    public init(settlementId: String, tripId: String, from: MiembroId, to: MiembroId, transferIndex: Int, amountMinor: Int64) {
        self.settlementId = settlementId; self.tripId = tripId
        self.from = from; self.to = to
        self.transferIndex = transferIndex; self.amountMinor = amountMinor
    }
}

public extension Settlement {
    /// Clave de dedupe estructural (ADR-0015 §5). El importe NO entra: reintentar el
    /// mismo pago con otro importe sigue siendo el mismo pago (ON CONFLICT DO NOTHING).
    /// La BD la materializa como uuidv5(settlementId, from||to||transferIndex).
    var idDeterminista: String { "\(settlementId)|\(from.raw)|\(to.raw)|\(transferIndex)" }
}
