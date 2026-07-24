import Foundation
import TripSquadDomain

/// Estado de una afirmación de pago (ADR-0017). Solo `confirmed` mueve saldos.
public enum EstadoSettlement: String, Sendable, Equatable {
    case pending, confirmed, rejected, cancelled
}

/// Una afirmación de pago entre dos miembros (ADR-0017). Nace `pending`; la contraparte
/// la confirma o rechaza. Append-only: las transiciones no borran, cambian estado.
public struct Settlement: Equatable, Sendable {
    public let settlementId: String   // generado en cliente; parte de la clave natural
    public let tripId: String
    public let from: MiembroId
    public let to: MiembroId
    public let transferIndex: Int
    public let amountMinor: Int64
    public let createdBy: MiembroId   // quién la creó → define la contraparte
    public let expiresAt: Date
    public var status: EstadoSettlement
    public var resolvedBy: MiembroId?
    public var resolvedAt: Date?
    public var rejectReason: String?

    public init(settlementId: String, tripId: String, from: MiembroId, to: MiembroId,
                transferIndex: Int, amountMinor: Int64, createdBy: MiembroId, expiresAt: Date,
                status: EstadoSettlement = .pending, resolvedBy: MiembroId? = nil,
                resolvedAt: Date? = nil, rejectReason: String? = nil) {
        self.settlementId = settlementId; self.tripId = tripId
        self.from = from; self.to = to
        self.transferIndex = transferIndex; self.amountMinor = amountMinor
        self.createdBy = createdBy; self.expiresAt = expiresAt
        self.status = status; self.resolvedBy = resolvedBy
        self.resolvedAt = resolvedAt; self.rejectReason = rejectReason
    }
}

/// Clave natural de dedupe (ADR-0015 §5), AHORA con `tripId` (fix B de la revisión
/// multi-modelo) y sin concatenación ambigua: es un valor estructurado Hashable, no una
/// cadena con separador. El importe NO entra: reintentar el mismo pago con otro importe es
/// el mismo pago.
public struct ClaveSettlement: Hashable, Sendable {
    public let tripId: String
    public let settlementId: String
    public let from: MiembroId
    public let to: MiembroId
    public let transferIndex: Int
}

public extension Settlement {
    var clave: ClaveSettlement {
        ClaveSettlement(tripId: tripId, settlementId: settlementId, from: from, to: to, transferIndex: transferIndex)
    }
}
