// Invariantes sobre `liquidar` (modo simplificado, ADR-0011 §6, 9–16).

import Testing
@testable import TripSquadDomain

@Suite("Liquidación — invariantes")
struct LiquidacionTests {

    /// (9) Corrección: aplicar las transferencias deja todos los saldos a 0.
    @Test func aplicarTransferenciasDejaTodoACero() {
        forAll("settle correcto") { rng in
            let saldos = try! balances(Escenario.gastos(&rng))
            let ts = liquidar(saldos)
            let restante = aplicar(ts, a: saldos)
            #expect(restante.values.allSatisfy { $0 == 0 }, "saldos: \(saldos)")
        }
    }

    /// (10) Suma cero de transferencias: el neto de cada persona por las
    /// transferencias iguala exactamente su saldo (paga lo que debe, cobra lo suyo).
    @Test func sumaCeroDeTransferenciasPorPersona() {
        forAll("suma transfers") { rng in
            let saldos = try! balances(Escenario.gastos(&rng))
            var neto: [MiembroId: Int64] = [:]
            for t in liquidar(saldos) {
                neto[t.de, default: 0] -= t.importeMinor  // paga
                neto[t.a, default: 0] += t.importeMinor    // cobra
            }
            let claves = Set(saldos.keys).union(neto.keys)
            for m in claves {
                #expect((neto[m] ?? 0) == (saldos[m] ?? 0), "miembro \(m), saldos: \(saldos)")
            }
        }
    }

    /// (11) Cota dura `|T| ≤ N−1`, y dos-pasadas NUNCA peor que el greedy solo.
    @Test func cotaNmenosUnoYNuncaPeorQueGreedy() {
        forAll("|T|<=N-1") { rng in
            let saldos = (try! balances(Escenario.gastos(&rng))).filter { $0.value != 0 }
            let n = saldos.count
            let ts = liquidar(saldos)
            if n == 0 {
                #expect(ts.isEmpty)
            } else {
                #expect(ts.count <= n - 1, "n=\(n), |T|=\(ts.count), saldos: \(saldos)")
            }
            #expect(ts.count <= greedy(saldos).count, "dos-pasadas peor que greedy: \(saldos)")
        }
    }

    /// (12) Positividad: todo importe > 0; nunca `p → p`.
    @Test func positividad() {
        forAll("positividad") { rng in
            let saldos = try! balances(Escenario.gastos(&rng))
            for t in liquidar(saldos) {
                #expect(t.importeMinor > 0, "importe no positivo: \(t)")
                #expect(t.de != t.a, "transferencia a sí mismo: \(t)")
            }
        }
    }

    /// (13) Nadie paga de más: un acreedor (saldo positivo) jamás aparece como
    /// pagador; un deudor jamás como receptor.
    @Test func nadiePagaDeMas() {
        forAll("nadie paga de más") { rng in
            let saldos = try! balances(Escenario.gastos(&rng))
            for t in liquidar(saldos) {
                #expect((saldos[t.de] ?? 0) < 0, "un no-deudor paga: \(t), saldos: \(saldos)")
                #expect((saldos[t.a] ?? 0) > 0, "un no-acreedor cobra: \(t), saldos: \(saldos)")
            }
        }
    }

    /// (14) Idempotencia: simplificar lo ya simplificado no hace nada.
    @Test func idempotencia() {
        forAll("idempotencia") { rng in
            let saldos = try! balances(Escenario.gastos(&rng))
            let despues = aplicar(liquidar(saldos), a: saldos)
            #expect(liquidar(despues).isEmpty, "saldos: \(saldos)")
        }
    }

    /// (15) Determinismo byte a byte: la misma entrada da siempre la misma salida.
    @Test func determinismoByteAByte() {
        forAll("determinismo") { rng in
            let saldos = try! balances(Escenario.gastos(&rng))
            #expect(liquidar(saldos) == liquidar(saldos), "saldos: \(saldos)")
        }
    }

    /// (16) Estabilidad ante permutación: reconstruir el diccionario en otro orden
    /// no cambia la salida (el motor ordena por `miembroId`, no depende del `Set`).
    @Test func estabilidadAntePermutacion() {
        forAll("estabilidad") { rng in
            let saldos = try! balances(Escenario.gastos(&rng))
            let rebarajado = Dictionary(uniqueKeysWithValues: saldos.shuffled(using: &rng))
            #expect(liquidar(saldos) == liquidar(rebarajado), "saldos: \(saldos)")
        }
    }
}
