import TripSquadDomain

/// Saldo neto tras aplicar los pagos CONFIRMADOS (ADR-0017): solo `confirmed` mueve saldos.
/// `from` pagó a `to`, así que reduce la deuda de `from` y el crédito de `to`.
public func balancesConLiquidaciones(_ gastos: [Gasto], confirmados: [Settlement]) throws -> [MiembroId: Int64] {
    var neto = try balances(gastos)
    for s in confirmados {
        neto[s.from, default: 0] += s.amountMinor
        neto[s.to, default: 0] -= s.amountMinor
    }
    return neto
}
