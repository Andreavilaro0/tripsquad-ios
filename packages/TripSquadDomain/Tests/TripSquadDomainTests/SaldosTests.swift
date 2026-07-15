// Invariantes sobre `balances` (ADR-0011 §6, 1–7).

import Testing
@testable import TripSquadDomain

@Suite("Saldos — invariantes")
struct SaldosTests {

    /// (1) Suma cero — la invariante maestra.
    @Test func sumaCero() {
        forAll("suma cero") { rng in
            let gastos = Escenario.gastos(&rng)
            let b = try! balances(gastos)
            #expect(b.values.reduce(0, +) == 0, "gastos: \(gastos)")
        }
    }

    /// (2) Conservación del total: lo pagado == lo asignado, ningún céntimo se
    /// crea ni se destruye.
    @Test func conservacionDelTotal() {
        forAll("conservación") { rng in
            let gastos = Escenario.gastos(&rng)
            let totalPagado = gastos.reduce(Int64(0)) { $0 + $1.importeMinor }
            let totalAsignado = gastos.reduce(Int64(0)) { acc, g in
                acc + (try! cuotas(de: g)).values.reduce(0, +)
            }
            #expect(totalPagado == totalAsignado, "gastos: \(gastos)")
        }
    }

    /// (3) `Σ cuotas(gasto) == importe(gasto)` exacto, para cada gasto.
    @Test func cuotasSumanElImporte() {
        forAll("cuotas suman") { rng in
            for g in Escenario.gastos(&rng) {
                let c = try! cuotas(de: g)
                #expect(c.values.reduce(0, +) == g.importeMinor, "gasto: \(g)")
            }
        }
    }

    /// (4) En reparto equitativo, `max(cuota) − min(cuota) ≤ 1` céntimo.
    @Test func repartoEquitativoDifiereComoMuchoUnCentimo() {
        forAll("equitativo <=1") { rng in
            let k = rng.entero(2...12)
            let pool = (0..<k).map { MiembroId("m\($0)") }
            let importe = rng.entero64(1...10_000_000)
            let participantes = Escenario.subsetNoVacio(pool, &rng)
            let g = Gasto(id: "g", pagadoPor: pool[0], importeMinor: importe,
                          reparto: .igual(entre: participantes))
            let c = try! cuotas(de: g)
            #expect((c.values.max()! - c.values.min()!) <= 1, "gasto: \(g)")
        }
    }

    /// (5) Permutación: `balances(shuffle(E)) == balances(E)`. Mata bugs de
    /// acumulación e iteración sobre `Set`.
    @Test func permutacionNoAfectaLosSaldos() {
        forAll("permutación") { rng in
            let gastos = Escenario.gastos(&rng)
            var barajados = gastos
            barajados.shuffle(using: &rng)
            #expect(try! balances(gastos) == (try! balances(barajados)), "gastos: \(gastos)")
        }
    }

    /// (6) Elemento neutro: un gasto de importe 0 no cambia los saldos.
    @Test func gastoDeImporteCeroEsNeutro() {
        forAll("neutro") { rng in
            let gastos = Escenario.gastos(&rng)
            let antes = (try! balances(gastos)).filter { $0.value != 0 }
            let cero = Gasto(id: "cero", pagadoPor: MiembroId("m0"), importeMinor: 0,
                             reparto: .igual(entre: [MiembroId("m0"), MiembroId("m1")]))
            let despues = (try! balances(gastos + [cero])).filter { $0.value != 0 }
            #expect(antes == despues, "gastos: \(gastos)")
        }
    }

    /// (7) Aditividad: los saldos de `A ++ B` son la suma miembro a miembro de los
    /// saldos de `A` y de `B` por separado.
    @Test func aditividad() {
        forAll("aditividad") { rng in
            let a = Escenario.gastos(&rng)
            let b = Escenario.gastos(&rng)
            let combinado = try! balances(a + b)
            let sa = try! balances(a)
            let sb = try! balances(b)
            var sumaManual = sa
            for (m, v) in sb { sumaManual[m, default: 0] += v }
            let claves = Set(combinado.keys).union(sumaManual.keys)
            for m in claves {
                #expect((combinado[m] ?? 0) == (sumaManual[m] ?? 0), "miembro \(m)")
            }
        }
    }
}
