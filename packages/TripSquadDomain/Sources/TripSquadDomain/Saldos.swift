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
        neto[gasto.pagadoPor, default: 0] += gasto.importeMinor
        // ...y cada participante (incluido el pagador) asume su cuota.
        for (miembro, cuota) in cuotasGasto {
            neto[miembro, default: 0] -= cuota
        }
    }
    return neto
}
