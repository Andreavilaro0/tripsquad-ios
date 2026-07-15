// Harness de property-based testing propio, con semilla y reproducible.
//
// ADR-0011 §7 elige `PropertyBased` (x-sheep) como framework, pero deja escrito
// que portar las invariantes a un generador propio "es un día de trabajo" y que el
// dominio NO se acopla al framework de tests. Para el primer corte se usa este
// runner propio: cero dependencias externas, verde garantizado y totalmente en
// nuestro control. Migrar a PropertyBased es un bead de seguimiento.
//
// Cada propiedad corre 200 iteraciones; en un fallo, el `#expect` imprime el caso
// generado para que sea reproducible.

import Testing
@testable import TripSquadDomain

/// RNG determinista (xorshift64*). La misma semilla da siempre la misma secuencia.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
    mutating func entero(_ r: ClosedRange<Int>) -> Int {
        Int(next() % UInt64(r.count)) + r.lowerBound
    }
    mutating func entero64(_ r: ClosedRange<Int64>) -> Int64 {
        Int64(next() % UInt64(r.count)) + r.lowerBound
    }
    mutating func siNo() -> Bool { next() & 1 == 0 }
}

/// Corre `cuerpo` sobre `iteraciones` casos aleatorios pero deterministas.
func forAll(
    _ nombre: String,
    iteraciones: Int = 200,
    semilla: UInt64 = 0xC0FF_EE00_1234_5678,
    _ cuerpo: (inout SeededRNG) -> Void
) {
    var maestro = SeededRNG(seed: semilla)
    for _ in 0..<iteraciones {
        var local = SeededRNG(seed: maestro.next())
        cuerpo(&local)
    }
}

// MARK: - Generadores

enum Escenario {
    /// Un pool de 2–12 miembros y 0–40 gastos con repartos variados (igual, por
    /// peso, exacto), pagadores repetidos e importes que fuerzan restos.
    static func gastos(_ rng: inout SeededRNG) -> [Gasto] {
        let k = rng.entero(2...12)
        let pool = (0..<k).map { MiembroId("m\($0)") }
        let numGastos = rng.entero(0...40)
        var lista: [Gasto] = []
        for i in 0..<numGastos {
            let pagador = pool[rng.entero(0...(k - 1))]
            let importe = rng.entero64(1...10_000_000)
            let participantes = subsetNoVacio(pool, &rng)
            let reparto: Reparto
            switch rng.entero(0...2) {
            case 0:
                reparto = .igual(entre: participantes)
            case 1:
                var pesos: [MiembroId: Int] = [:]
                for m in participantes { pesos[m] = rng.entero(1...10) }
                reparto = .porPeso(pesos)
            default:
                reparto = .exacto(exacto(importe: importe, entre: participantes))
            }
            lista.append(Gasto(id: "g\(i)", pagadoPor: pagador, importeMinor: importe, reparto: reparto))
        }
        return lista
    }

    /// Subconjunto no vacío del pool (cada miembro con prob. ~1/2).
    static func subsetNoVacio(_ pool: [MiembroId], _ rng: inout SeededRNG) -> [MiembroId] {
        var elegidos = pool.filter { _ in rng.siNo() }
        if elegidos.isEmpty { elegidos = [pool[rng.entero(0...(pool.count - 1))]] }
        return elegidos
    }

    /// Parte `importe` en cuotas exactas que suman exactamente `importe`
    /// (largest remainder por orden), para ejercitar el camino `.exacto`.
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
