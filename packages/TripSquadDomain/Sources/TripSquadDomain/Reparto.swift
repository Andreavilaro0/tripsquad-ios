// Reparto de un gasto en cuotas por participante.
//
// Regla maestra (ADR-0011 §3): la suma de las cuotas es SIEMPRE exactamente el
// importe del gasto. Ni se crea ni se destruye un céntimo. Con división entera +
// "largest remainder", la conservación es por construcción, no por redondeo.

/// Calcula las cuotas de un gasto: cuánto le corresponde asumir a cada miembro.
/// Devuelve un mapa `MiembroId -> céntimos` cuya suma es exactamente `importeMinor`.
public func cuotas(de gasto: Gasto) throws -> [MiembroId: Int64] {
    guard gasto.importeMinor >= 0 else { throw DomainError.importeNegativo }

    switch gasto.reparto {
    case .igual(let entre):
        guard !entre.isEmpty else { throw DomainError.sinParticipantes }
        try exigirSinDuplicados(entre)
        return repartoIgual(importe: gasto.importeMinor, entre: entre, pagador: gasto.pagadoPor)

    case .porPeso(let pesos):
        guard !pesos.isEmpty else { throw DomainError.sinParticipantes }
        return try repartoPorPeso(importe: gasto.importeMinor, pesos: pesos)

    case .exacto(let exactas):
        guard !exactas.isEmpty else { throw DomainError.sinParticipantes }
        for v in exactas.values where v < 0 { throw DomainError.importeNegativo }
        guard exactas.values.reduce(0, +) == gasto.importeMinor else {
            throw DomainError.cuotasNoCuadran
        }
        return exactas
    }
}

// MARK: - Reparto igualitario (largest remainder)

/// `base = importe / n`, `rem = importe % n`. A los primeros `rem` participantes,
/// en orden determinista, se les suma 1 céntimo. El orden pone al **pagador
/// primero** (si participa) y luego por `miembroId` ascendente, de modo que el
/// céntimo sobrante lo asuma quien adelantó el dinero (ADR-0011 §8.1).
///
/// Decisión consciente (no es un bug): si el pagador **no participa**, no tiene
/// cuota que absorber el céntimo, así que el resto cae al primer participante por
/// `miembroId`. Sigue siendo determinista y conserva el total exacto.
func repartoIgual(importe: Int64, entre: [MiembroId], pagador: MiembroId) -> [MiembroId: Int64] {
    let n = Int64(entre.count)
    let base = importe / n
    let rem = Int(importe % n)

    var ordenados = entre.sorted()
    if let idx = ordenados.firstIndex(of: pagador) {
        ordenados.remove(at: idx)
        ordenados.insert(pagador, at: 0)
    }

    var resultado: [MiembroId: Int64] = [:]
    for (i, m) in ordenados.enumerated() {
        resultado[m] = base + (i < rem ? 1 : 0)
    }
    return resultado
}

// MARK: - Reparto por peso (largest remainder ponderado)

/// `cuotaᵢ = floor(importe·wᵢ / Σw)`; los restos se reparten uno a uno por parte
/// fraccionaria descendente, con desempate estable por `miembroId` (ADR-0011 §3).
func repartoPorPeso(importe: Int64, pesos: [MiembroId: Int]) throws -> [MiembroId: Int64] {
    for w in pesos.values where w <= 0 { throw DomainError.pesoInvalido }
    // Suma en Int64 desde el principio (evita overflow del `Int` en la reducción,
    // hallazgo de la voz externa Gemini) y con sumas seguras.
    var sumaPesos: Int64 = 0
    for w in pesos.values {
        let (s, overflow) = sumaPesos.addingReportingOverflow(Int64(w))
        guard !overflow else { throw DomainError.pesoInvalido }
        sumaPesos = s
    }
    guard sumaPesos > 0 else { throw DomainError.pesoInvalido }

    var resultado: [MiembroId: Int64] = [:]
    var restos: [(m: MiembroId, resto: Int64)] = []
    var asignado: Int64 = 0

    let sw = UInt64(sumaPesos)
    for (m, w) in pesos {
        // `importe * peso` puede desbordar Int64 con importes o pesos grandes
        // (hallazgo P0 de Gemini). Se hace el producto a 128 bits con
        // `multipliedFullWidth` y se divide con `dividingFullWidth` — sin `Int128`
        // (que exige macOS 15) y sin `Double`. Todo es no-negativo aquí (importe ≥ 0,
        // peso > 0), así que UInt64 es seguro; la cuota (≤ importe) cabe en Int64.
        let producto = UInt64(importe).multipliedFullWidth(by: UInt64(w))
        let (cuotaU, restoU) = sw.dividingFullWidth(producto)
        let cuota = Int64(cuotaU)
        let resto = Int64(restoU)
        resultado[m] = cuota
        asignado += cuota
        restos.append((m, resto))
    }

    var sobrante = importe - asignado
    // Orden determinista: resto mayor primero; empate -> miembroId ascendente.
    let orden = restos.sorted { a, b in
        a.resto != b.resto ? a.resto > b.resto : a.m < b.m
    }
    var i = 0
    while sobrante > 0 && i < orden.count {
        resultado[orden[i].m, default: 0] += 1
        sobrante -= 1
        i += 1
    }
    return resultado
}

// MARK: - Utilidad

func exigirSinDuplicados(_ miembros: [MiembroId]) throws {
    var vistos = Set<MiembroId>()
    for m in miembros {
        if !vistos.insert(m).inserted { throw DomainError.miembroDuplicado }
    }
}
