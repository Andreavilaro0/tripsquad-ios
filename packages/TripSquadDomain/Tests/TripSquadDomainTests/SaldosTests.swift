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

    // MARK: - Overflow: error de dominio, NUNCA una caída del proceso

    // P1 de la revisión integrada. `Dinero.minorUnits` acepta importes hasta Int64.max,
    // y `+=`/`-=` de Swift TRAPEAN en overflow (SIGTRAP: mata el proceso, ningún catch
    // lo recoge). Como el gasto ya está PERSISTIDO cuando se calculan los saldos, dos
    // gastos gigantes envenenaban el viaje para siempre: cada sugerencia de settle y
    // cada consulta de Brújula tumbaban el servicio, que sirve a todos los viajes.
    // Estos tests fijan que ahora sea un error normal.

    /// Dos gastos que individualmente caben, pero cuyo ACUMULADO no.
    ///
    /// El reparto importa: si el pagador asume su propia cuota, lo que suma se le
    /// resta dentro del mismo gasto y el neto vuelve a 0 (nunca acumula). El caso
    /// que sí crece es el pagador que NO participa: adelanta el importe entero y la
    /// cuota es de otro, así que su saldo se acumula gasto a gasto.
    @Test func balancesConAcumuladoFueraDeRangoLanzaEnVezDeTrapear() throws {
        let ana = MiembroId("ana"), ivan = MiembroId("ivan")
        let g1 = Gasto(id: "g1", pagadoPor: ana, importeMinor: Int64.max,
                       reparto: .exacto([ivan: Int64.max]))
        let g2 = Gasto(id: "g2", pagadoPor: ana, importeMinor: Int64.max,
                       reparto: .exacto([ivan: Int64.max]))
        // Uno solo cabe justo.
        #expect(try balances([g1])[ana] == Int64.max)
        // Dos: el acumulado de ana se sale de Int64 -> error, no SIGTRAP.
        #expect(throws: DomainError.saldoFueraDeRango) {
            _ = try balances([g1, g2])
        }
    }

    /// La suma de cuotas exactas tampoco puede trapear.
    @Test func cuotasExactasFueraDeRangoLanzaEnVezDeTrapear() throws {
        let ana = MiembroId("ana"), ivan = MiembroId("ivan")
        let gasto = Gasto(id: "g1", pagadoPor: ana, importeMinor: 100,
                          reparto: .exacto([ana: Int64.max, ivan: Int64.max]))
        #expect(throws: DomainError.saldoFueraDeRango) {
            _ = try cuotas(de: gasto)
        }
    }
}
