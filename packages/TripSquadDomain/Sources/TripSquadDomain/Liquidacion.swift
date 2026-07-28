// Liquidación (modo simplificado): convierte el vector de saldos netos en una
// lista mínima-ish de transferencias.
//
// El mínimo exacto de transferencias es NP-completo (ADR-0011 §1), así que NO se
// busca. Se hacen dos pasadas: (1) descomposición en subgrupos de suma cero
// pequeños (pares y tríos), que capturan la mayor parte de la mejora a coste
// trivial para N ≤ 12; (2) greedy sobre el resto, con la cota dura `|T| ≤ N−1`.
// Para garantizar que dos-pasadas NUNCA es peor que el greedy solo, se calculan
// ambas y se devuelve la de menos transferencias (empate → dos-pasadas).
//
// Todo el orden es estable por `miembroId`: la misma entrada da siempre la misma
// salida, byte a byte (ADR-0011 §1, invariante de determinismo).

/// Sugiere las transferencias que dejan todos los saldos a cero.
public func liquidar(_ saldos: [MiembroId: Int64]) -> [Transferencia] {
    let neto = saldos.filter { $0.value != 0 }
    if neto.isEmpty { return [] }

    let soloGreedy = greedy(neto)
    let dosPasadas = descomponerYGreedy(neto)
    return dosPasadas.count <= soloGreedy.count ? dosPasadas : soloGreedy
}

// MARK: - Greedy max-deudor / max-acreedor

/// Empareja al que más se le debe con el que más debe, transfiere el mínimo de los
/// dos, repite. Cada iteración deja al menos a uno a cero → cota `N−1`. Desempates
/// estables por `miembroId`.
func greedy(_ saldos: [MiembroId: Int64]) -> [Transferencia] {
    var bal = saldos
    var salida: [Transferencia] = []

    while true {
        // Máximo acreedor: mayor saldo positivo; empate -> miembroId menor.
        let acreedor = bal.filter { $0.value > 0 }.min { a, b in
            a.value != b.value ? a.value > b.value : a.key < b.key
        }
        // Máximo deudor: saldo más negativo; empate -> miembroId menor.
        let deudor = bal.filter { $0.value < 0 }.min { a, b in
            a.value != b.value ? a.value < b.value : a.key < b.key
        }
        guard let c = acreedor, let d = deudor else { break }

        let importe = min(c.value, -d.value)
        salida.append(Transferencia(de: d.key, a: c.key, importeMinor: importe))
        bal[c.key]! -= importe
        bal[d.key]! += importe
        if bal[c.key] == 0 { bal[c.key] = nil }
        if bal[d.key] == 0 { bal[d.key] = nil }
    }
    return salida
}

// MARK: - Dos pasadas

/// Pasada 1: extrae pares exactos (deudor con crédito opuesto exacto) y tríos de
/// suma cero. Pasada 2: greedy sobre lo que queda.
func descomponerYGreedy(_ saldos: [MiembroId: Int64]) -> [Transferencia] {
    var bal = saldos
    var salida: [Transferencia] = []

    // Pasada 1a: pares exactos (a debe exactamente lo que a b se le debe).
    var huboCambio = true
    while huboCambio {
        huboCambio = false
        for d in bal.filter({ $0.value < 0 }).keys.sorted() {
            guard let dv = bal[d], dv < 0 else { continue }
            let acreedoresExactos = bal.filter { $0.value == -dv }.keys.sorted()
            if let c = acreedoresExactos.first {
                salida.append(Transferencia(de: d, a: c, importeMinor: -dv))
                bal[d] = nil
                bal[c] = nil
                huboCambio = true
            }
        }
    }

    // Pasada 1b: tríos de suma cero, en orden determinista por miembroId.
    while true {
        let ms = bal.keys.sorted()
        var encontrado = false
        if ms.count >= 3 {
            busqueda: for i in 0..<ms.count {
                for j in (i + 1)..<ms.count {
                    for k in (j + 1)..<ms.count {
                        if bal[ms[i]]! + bal[ms[j]]! + bal[ms[k]]! == 0 {
                            let sub = [ms[i]: bal[ms[i]]!, ms[j]: bal[ms[j]]!, ms[k]: bal[ms[k]]!]
                            salida.append(contentsOf: greedy(sub))
                            bal[ms[i]] = nil
                            bal[ms[j]] = nil
                            bal[ms[k]] = nil
                            encontrado = true
                            break busqueda
                        }
                    }
                }
            }
        }
        if !encontrado { break }
    }

    // Pasada 2: greedy sobre el resto.
    salida.append(contentsOf: greedy(bal))
    return salida
}
