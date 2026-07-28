// Generadores de property-based testing sobre PropertyBased (x-sheep).
//
// ADR-0011 §7 elige `PropertyBased` como framework de property testing. Sustituye
// al runner propio (SplitMix64/xorshift, 200 iteraciones): PropertyBased aporta
// SHRINKING automático (reduce el contraejemplo al caso mínimo) y REPORTA la
// semilla del fallo para reproducirlo con `.fixedSeed(...)`.
//
// Restricción (ADR-0011 §7, bead 9dn): PropertyBased vive SOLO en el target de
// tests. El dominio (`TripSquadDomain`) sigue sin dependencias externas.
//
// Aquí viven únicamente los GENERADORES y utilidades compartidas por las suites.
// Las propiedades se escriben en Saldos/Liquidacion con `propertyCheck`.

import PropertyBased
import Testing
@testable import TripSquadDomain

// MARK: - Universo de miembros

/// Universo fijo de hasta 12 miembros. El tamaño real del pool (2...12) se elige
/// por escenario y recorta el universo a sus primeros `k` miembros. Trabajar sobre
/// un universo fijo permite componer los generadores sin generación dependiente.
let universoMiembros: [MiembroId] = (0..<12).map { MiembroId("m\($0)") }

// MARK: - Semilla de un gasto (datos primitivos, shrinkables por PropertyBased)

/// La forma "cruda" de un gasto: enteros y flags que PropertyBased sabe encoger.
/// `construir(k:seeds:)` la interpreta contra el pool para producir `Gasto`s válidos.
struct GastoSeed {
    /// Índice del pagador (se toma módulo `k`).
    let pagadorRaw: Int
    /// Importe en céntimos, 1...10_000_000 (fuerza restos sin arriesgar overflow).
    let importe: Int
    /// 0 = igual, 1 = por peso, 2 = exacto.
    let kind: Int
    /// Máscara de participación sobre el universo (12 flags).
    let inclusion: [Bool]
    /// Pesos 1...10 por posición del universo (solo se usan en `.porPeso`).
    let pesos: [Int]
}

// MARK: - Generadores

enum Escenario {
    /// Generador de una semilla de gasto, compuesto de generadores primitivos con
    /// shrinking integrado (int hacia el mínimo del rango, array quitando elementos).
    static let gastoSeed = zip(
        zip(Gen.int(in: 0...11), Gen.int(in: 1...10_000_000), Gen.int(in: 0...2)),
        zip(Gen.bool.array(of: 12...12), Gen.int(in: 1...10).array(of: 12...12))
    ).map { nums, cols in
        GastoSeed(pagadorRaw: nums.0, importe: nums.1, kind: nums.2,
                  inclusion: cols.0, pesos: cols.1)
    }

    /// Generador de un escenario: un pool de 2–12 miembros y 0–40 gastos con
    /// repartos variados (igual, por peso, exacto), pagadores repetidos e importes
    /// que fuerzan restos. Equivalente en cobertura al `Escenario.gastos` previo.
    static let gastos = zip(Gen.int(in: 2...12), gastoSeed.array(of: 0...40))
        .map { k, seeds in construir(k: k, seeds: seeds) }

    // MARK: Interpretación de las semillas

    static func construir(k: Int, seeds: [GastoSeed]) -> [Gasto] {
        let pool = Array(universoMiembros.prefix(k))
        var lista: [Gasto] = []
        for (i, s) in seeds.enumerated() {
            let pagador = pool[s.pagadorRaw % k]
            let importe = Int64(s.importe)
            let participantes = subset(pool, inclusion: s.inclusion, fallbackIndex: s.importe % k)
            let reparto: Reparto
            switch s.kind {
            case 0:
                reparto = .igual(entre: participantes)
            case 1:
                var pesos: [MiembroId: Int] = [:]
                for (idx, m) in pool.enumerated() where s.inclusion[idx] { pesos[m] = s.pesos[idx] }
                if pesos.isEmpty { pesos[participantes[0]] = s.pesos[s.importe % k] }
                reparto = .porPeso(pesos)
            default:
                reparto = .exacto(exacto(importe: importe, entre: participantes))
            }
            lista.append(Gasto(id: "g\(i)", pagadoPor: pagador, importeMinor: importe, reparto: reparto))
        }
        return lista
    }

    /// Subconjunto no vacío del pool según la máscara `inclusion`; si queda vacío,
    /// elige un único miembro determinista.
    static func subset(_ pool: [MiembroId], inclusion: [Bool], fallbackIndex: Int) -> [MiembroId] {
        let elegidos = pool.enumerated().filter { inclusion[$0.offset] }.map { $0.element }
        return elegidos.isEmpty ? [pool[fallbackIndex]] : elegidos
    }

    /// Parte `importe` en cuotas exactas que suman exactamente `importe`
    /// (largest remainder por orden de id), para ejercitar el camino `.exacto`.
    static func exacto(importe: Int64, entre: [MiembroId]) -> [MiembroId: Int64] {
        let n = Int64(entre.count)
        let base = importe / n
        let rem = Int(importe % n)
        var resultado: [MiembroId: Int64] = [:]
        for (i, m) in entre.sorted().enumerated() {
            resultado[m] = base + (i < rem ? 1 : 0)
        }
        return resultado
    }
}

// MARK: - Utilidades

/// Aplica una lista de transferencias a un vector de saldos: el deudor sube hacia
/// cero (paga), el acreedor baja hacia cero (cobra).
func aplicar(_ transferencias: [Transferencia], a saldos: [MiembroId: Int64]) -> [MiembroId: Int64] {
    var b = saldos
    for t in transferencias {
        b[t.de, default: 0] += t.importeMinor
        b[t.a, default: 0] -= t.importeMinor
    }
    return b
}
