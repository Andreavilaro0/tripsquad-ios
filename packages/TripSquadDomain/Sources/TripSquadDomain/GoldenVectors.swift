// Golden vectors: casos canónicos (entrada -> saldos + transferencias esperadas)
// que el motor Swift genera y que el port de Kotlin deberá reproducir byte a byte
// (ADR-0015 §3, bead 0i9). Este archivo define el modelo serializable y el
// generador determinista; el fichero `golden-vectors.json` se produce con
// `swift run generate-golden-vectors` y se versiona en el repo.
//
// Serialización con claves ordenadas: el JSON es estable, así que "determinismo
// byte a byte" se comprueba con un simple diff.

import Foundation

public struct GoldenCase: Codable, Equatable, Sendable {
    public var id: String
    public var currency: String
    public var expenses: [GoldenExpense]
    public var expectedBalances: [String: Int64]
    public var expectedTransfers: [GoldenTransfer]
}

public struct GoldenExpense: Codable, Equatable, Sendable {
    public var id: String
    public var paidBy: String
    public var amountMinor: Int64
    public var split: GoldenSplit
}

public struct GoldenSplit: Codable, Equatable, Sendable {
    public var kind: String                 // "equal" | "weight" | "exact"
    public var among: [String]?             // equal
    public var weights: [String: Int]?      // weight
    public var exact: [String: Int64]?      // exact
}

public struct GoldenTransfer: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var amountMinor: Int64
}

public struct GoldenVectors: Codable, Equatable, Sendable {
    public var version: Int
    public var seed: UInt64
    public var cases: [GoldenCase]
}

public enum GoldenVectorsGen {
    /// Construye el conjunto de golden vectors: los casos de oro nombrados más una
    /// tanda determinista generada desde `seed`. La salida es estable para un
    /// mismo `seed`.
    public static func build(seed: UInt64 = 0x60D_60D_60D_60D, generados: Int = 500) -> GoldenVectors {
        var casos = casosDeOro()
        var rng = SplitMix64(seed: seed)
        for i in 0..<generados {
            casos.append(casoGenerado(indice: i, rng: &rng))
        }
        return GoldenVectors(version: 1, seed: seed, cases: casos)
    }

    /// JSON canónico: claves ordenadas + saltos de línea, para diffs limpios.
    public static func json(_ vectors: GoldenVectors) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(vectors)
    }

    // MARK: - Casos de oro nombrados

    static func casosDeOro() -> [GoldenCase] {
        [
            desdeGastos(id: "10eur-entre-3", currency: "EUR", gastos: [
                Gasto(id: "g1", pagadoPor: MiembroId("m1"), importeMinor: 1000,
                      reparto: .igual(entre: [MiembroId("m1"), MiembroId("m2"), MiembroId("m3")])),
            ]),
            desdeGastos(id: "1cent-entre-5", currency: "EUR", gastos: [
                Gasto(id: "g1", pagadoPor: MiembroId("m0"), importeMinor: 1,
                      reparto: .igual(entre: (0...4).map { MiembroId("m\($0)") })),
            ]),
            desdeGastos(id: "jpy-zero-decimal", currency: "JPY", gastos: [
                Gasto(id: "g1", pagadoPor: MiembroId("m1"), importeMinor: 3000,
                      reparto: .igual(entre: [MiembroId("m1"), MiembroId("m2")])),
            ]),
            desdeGastos(id: "grupo-de-uno", currency: "EUR", gastos: [
                Gasto(id: "g1", pagadoPor: MiembroId("m0"), importeMinor: 500,
                      reparto: .igual(entre: [MiembroId("m0")])),
            ]),
            desdeGastos(id: "pagador-no-participa", currency: "EUR", gastos: [
                Gasto(id: "g1", pagadoPor: MiembroId("m0"), importeMinor: 1000,
                      reparto: .igual(entre: [MiembroId("m1"), MiembroId("m2"), MiembroId("m3")])),
            ]),
            // Contraejemplo del greedy, como saldos directos.
            casoDesdeSaldos(id: "contraejemplo-greedy", currency: "EUR", saldos: [
                "a": -14, "b": -13, "c": 14, "d": 13, "e": 7, "f": 11, "g": -18,
            ]),
        ]
    }

    // MARK: - Construcción

    static func desdeGastos(id: String, currency: String, gastos: [Gasto]) -> GoldenCase {
        let saldos = try! balances(gastos)
        let transferencias = liquidar(saldos)
        return GoldenCase(
            id: id,
            currency: currency,
            expenses: gastos.map(golden),
            expectedBalances: mapear(saldos),
            expectedTransfers: transferencias.map { GoldenTransfer(from: $0.de.raw, to: $0.a.raw, amountMinor: $0.importeMinor) }
        )
    }

    static func casoDesdeSaldos(id: String, currency: String, saldos: [String: Int64]) -> GoldenCase {
        let net = Dictionary(uniqueKeysWithValues: saldos.map { (MiembroId($0.key), $0.value) })
        let transferencias = liquidar(net)
        return GoldenCase(
            id: id, currency: currency, expenses: [],
            expectedBalances: saldos,
            expectedTransfers: transferencias.map { GoldenTransfer(from: $0.de.raw, to: $0.a.raw, amountMinor: $0.importeMinor) }
        )
    }

    static func casoGenerado(indice: Int, rng: inout SplitMix64) -> GoldenCase {
        let k = Int(rng.next() % 11) + 2                  // 2...12 miembros
        let pool = (0..<k).map { MiembroId("m\($0)") }
        let numGastos = Int(rng.next() % 8) + 1           // 1...8 gastos
        var gastos: [Gasto] = []
        for i in 0..<numGastos {
            let pagador = pool[Int(rng.next() % UInt64(k))]
            let importe = Int64(rng.next() % 1_000_000) + 1
            let participantes = pool.filter { _ in rng.next() & 1 == 0 }
            let entre = participantes.isEmpty ? [pool[0]] : participantes
            gastos.append(Gasto(id: "g\(i)", pagadoPor: pagador, importeMinor: importe,
                                reparto: .igual(entre: entre)))
        }
        return desdeGastos(id: "gen-\(indice)", currency: "EUR", gastos: gastos)
    }

    static func golden(_ g: Gasto) -> GoldenExpense {
        let split: GoldenSplit
        switch g.reparto {
        case .igual(let e):
            split = GoldenSplit(kind: "equal", among: e.map(\.raw), weights: nil, exact: nil)
        case .porPeso(let w):
            split = GoldenSplit(kind: "weight", among: nil,
                                weights: Dictionary(uniqueKeysWithValues: w.map { ($0.key.raw, $0.value) }), exact: nil)
        case .exacto(let x):
            split = GoldenSplit(kind: "exact", among: nil, weights: nil,
                                exact: Dictionary(uniqueKeysWithValues: x.map { ($0.key.raw, $0.value) }))
        }
        return GoldenExpense(id: g.id, paidBy: g.pagadoPor.raw, amountMinor: g.importeMinor, split: split)
    }

    static func mapear(_ saldos: [MiembroId: Int64]) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: saldos.map { ($0.key.raw, $0.value) })
    }
}

/// SplitMix64 — RNG determinista para la generación de golden vectors. Igual de
/// portable a Kotlin (mismo algoritmo, mismos números).
public struct SplitMix64 {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
