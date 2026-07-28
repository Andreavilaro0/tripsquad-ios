import TripSquadDomain

/// Saldo neto tras aplicar los pagos CONFIRMADOS (ADR-0017): solo `confirmed` mueve saldos.
/// `from` pagó a `to`, así que reduce la deuda de `from` y el crédito de `to`.
public func balancesConLiquidaciones(_ gastos: [Gasto], confirmados: [Settlement]) throws -> [MiembroId: Int64] {
    var neto = try balances(gastos)
    for s in confirmados {
        // Aritmética COMPROBADA, igual que `balances`: `amountMinor` solo se valida
        // como `> 0` al crear el pago, así que un importe enorme confirmado trapearía
        // aquí y mataría el proceso en cada consulta posterior de ese viaje.
        try acumularSaldo(&neto, s.from, suma: s.amountMinor)
        try acumularSaldo(&neto, s.to, resta: s.amountMinor)
    }
    return neto
}
