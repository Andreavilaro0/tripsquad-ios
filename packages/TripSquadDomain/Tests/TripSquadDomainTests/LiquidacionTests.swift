// Invariantes sobre `liquidar` (modo simplificado, ADR-0011 §6, 9–16).
//
// Property-based con PropertyBased (x-sheep): shrinking automático y semilla del
// fallo reproducible. Los saldos se derivan de `balances(escenario)` para ejercitar
// el motor con vectores realistas (suma cero, restos, deudores y acreedores).

import PropertyBased
import Testing
@testable import TripSquadDomain

@Suite("Liquidación — invariantes")
struct LiquidacionTests {

    /// (9) Corrección: aplicar las transferencias deja todos los saldos a 0.
    @Test func aplicarTransferenciasDejaTodoACero() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let saldos = try! balances(gastos)
            let ts = liquidar(saldos)
            let restante = aplicar(ts, a: saldos)
            #expect(restante.values.allSatisfy { $0 == 0 })
        }
    }

    /// (10) Suma cero de transferencias: el neto de cada persona por las
    /// transferencias iguala exactamente su saldo (paga lo que debe, cobra lo suyo).
    @Test func sumaCeroDeTransferenciasPorPersona() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let saldos = try! balances(gastos)
            var neto: [MiembroId: Int64] = [:]
            for t in liquidar(saldos) {
                neto[t.de, default: 0] -= t.importeMinor  // paga
                neto[t.a, default: 0] += t.importeMinor    // cobra
            }
            let claves = Set(saldos.keys).union(neto.keys)
            for m in claves {
                #expect((neto[m] ?? 0) == (saldos[m] ?? 0))
            }
        }
    }

    /// (11) Cota dura `|T| ≤ N−1`, y dos-pasadas NUNCA peor que el greedy solo.
    @Test func cotaNmenosUnoYNuncaPeorQueGreedy() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let saldos = (try! balances(gastos)).filter { $0.value != 0 }
            let n = saldos.count
            let ts = liquidar(saldos)
            if n == 0 {
                #expect(ts.isEmpty)
            } else {
                #expect(ts.count <= n - 1)
            }
            #expect(ts.count <= greedy(saldos).count)
        }
    }

    /// (12) Positividad: todo importe > 0; nunca `p → p`.
    @Test func positividad() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let saldos = try! balances(gastos)
            for t in liquidar(saldos) {
                #expect(t.importeMinor > 0)
                #expect(t.de != t.a)
            }
        }
    }

    /// (13) Nadie paga de más: un acreedor (saldo positivo) jamás aparece como
    /// pagador; un deudor jamás como receptor.
    @Test func nadiePagaDeMas() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let saldos = try! balances(gastos)
            for t in liquidar(saldos) {
                #expect((saldos[t.de] ?? 0) < 0)
                #expect((saldos[t.a] ?? 0) > 0)
            }
        }
    }

    /// (14) Idempotencia: simplificar lo ya simplificado no hace nada.
    @Test func idempotencia() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let saldos = try! balances(gastos)
            let despues = aplicar(liquidar(saldos), a: saldos)
            #expect(liquidar(despues).isEmpty)
        }
    }

    /// (15) Determinismo byte a byte: la misma entrada da siempre la misma salida.
    @Test func determinismoByteAByte() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let saldos = try! balances(gastos)
            #expect(liquidar(saldos) == liquidar(saldos))
        }
    }

    /// (16) Estabilidad ante permutación: reconstruir el diccionario en otro orden
    /// no cambia la salida (el motor ordena por `miembroId`, no depende del `Set`).
    @Test func estabilidadAntePermutacion() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let saldos = try! balances(gastos)
            let rebarajado = Dictionary(uniqueKeysWithValues: saldos.sorted { $0.key > $1.key })
            #expect(liquidar(saldos) == liquidar(rebarajado))
        }
    }
}
