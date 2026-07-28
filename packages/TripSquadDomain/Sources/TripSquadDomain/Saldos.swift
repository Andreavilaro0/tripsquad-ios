// Saldos netos.
//
// `neto(p) = Σ(pagado por p) − Σ(asignado a p)`. Por construcción `Σ neto = 0`
// (ADR-0011 §1): cada gasto suma su importe al pagador y resta ese mismo importe
// repartido en cuotas, así que el total siempre se cancela. Colapsa el grafo denso
// de deudas bilaterales en un vector de N números. Coste O(E).

/// Calcula el saldo neto de cada miembro a partir de la lista de gastos.
/// Positivo = le deben; negativo = debe. La suma de todos es exactamente 0.
public func balances(_ gastos: [Gasto]) throws -> [MiembroId: Int64] {
    var neto: [MiembroId: Int64] = [:]
    for gasto in gastos {
        let cuotasGasto = try cuotas(de: gasto)
        // El pagador adelantó el importe entero...
        try acumularSaldo(&neto, gasto.pagadoPor, suma: gasto.importeMinor)
        // ...y cada participante (incluido el pagador) asume su cuota.
        for (miembro, cuota) in cuotasGasto {
            try acumularSaldo(&neto, miembro, resta: cuota)
        }
    }
    return neto
}

// MARK: - Acumuladores con aritmética COMPROBADA

// `+=` y `-=` de Swift TRAPEAN en overflow (SIGTRAP: el proceso muere, no hay `catch`
// que lo recoja). Como el importe de un gasto puede llegar hasta `Int64.max` (ver el
// guard de rango de `Dinero.minorUnits`), acumular saldos con los operadores normales
// convierte un gasto en un arma: el gasto queda PERSISTIDO y a partir de ahí cualquier
// cálculo de saldos de ese viaje mata el servicio. Estos dos helpers convierten el
// overflow en un `DomainError` corriente. Son `public` porque `balancesConLiquidaciones`
// (módulo TripSquadExpenses) acumula sobre el mismo vector y necesita la misma garantía.

/// Suma `suma` al saldo de `miembro`, lanzando en vez de trapear si se sale de rango.
public func acumularSaldo(_ neto: inout [MiembroId: Int64], _ miembro: MiembroId, suma: Int64) throws {
    let (r, overflow) = neto[miembro, default: 0].addingReportingOverflow(suma)
    guard !overflow else { throw DomainError.saldoFueraDeRango }
    neto[miembro] = r
}

/// Resta `resta` del saldo de `miembro`, lanzando en vez de trapear si se sale de rango.
/// Se usa `subtractingReportingOverflow` en vez de sumar el negado porque negar
/// `Int64.min` también trapea.
public func acumularSaldo(_ neto: inout [MiembroId: Int64], _ miembro: MiembroId, resta: Int64) throws {
    let (r, overflow) = neto[miembro, default: 0].subtractingReportingOverflow(resta)
    guard !overflow else { throw DomainError.saldoFueraDeRango }
    neto[miembro] = r
}
