// Invariantes sobre `balances` (ADR-0011 §6, 1–7).
//
// Property-based con PropertyBased (x-sheep): shrinking automático al contraejemplo
// mínimo y semilla del fallo reproducible. En un fallo, PropertyBased imprime el
// caso encogido y la semilla (usar `.fixedSeed(...)` para reproducir).

import PropertyBased
import Testing
@testable import TripSquadDomain

@Suite("Saldos — invariantes")
struct SaldosTests {

    /// (1) Suma cero — la invariante maestra.
    @Test func sumaCero() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let b = try! balances(gastos)
            #expect(b.values.reduce(0, +) == 0)
        }
    }

    /// (2) Conservación del total: lo pagado == lo asignado, ningún céntimo se
    /// crea ni se destruye.
    @Test func conservacionDelTotal() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let totalPagado = gastos.reduce(Int64(0)) { $0 + $1.importeMinor }
            let totalAsignado = gastos.reduce(Int64(0)) { acc, g in
                acc + (try! cuotas(de: g)).values.reduce(0, +)
            }
            #expect(totalPagado == totalAsignado)
        }
    }

    /// (3) `Σ cuotas(gasto) == importe(gasto)` exacto, para cada gasto.
    @Test func cuotasSumanElImporte() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            for g in gastos {
                let c = try! cuotas(de: g)
                #expect(c.values.reduce(0, +) == g.importeMinor)
            }
        }
    }

    /// (4) En reparto equitativo, `max(cuota) − min(cuota) ≤ 1` céntimo.
    @Test func repartoEquitativoDifiereComoMuchoUnCentimo() async {
        await propertyCheck(input: zip(Gen.int(in: 2...12),
                                       Gen.int(in: 1...10_000_000),
                                       Gen.bool.array(of: 12...12))) { k, importe, inclusion in
            let pool = Array(universoMiembros.prefix(k))
            let participantes = Escenario.subset(pool, inclusion: inclusion, fallbackIndex: importe % k)
            let g = Gasto(id: "g", pagadoPor: pool[0], importeMinor: Int64(importe),
                          reparto: .igual(entre: participantes))
            let c = try! cuotas(de: g)
            #expect((c.values.max()! - c.values.min()!) <= 1)
        }
    }

    /// (5) Permutación: `balances(reordenar(E)) == balances(E)`. Mata bugs de
    /// acumulación e iteración sobre `Set`. El reorden es determinista (por importe
    /// y luego id) para que un fallo sea reproducible.
    @Test func permutacionNoAfectaLosSaldos() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let reordenados = gastos.sorted {
                $0.importeMinor != $1.importeMinor ? $0.importeMinor > $1.importeMinor : $0.id > $1.id
            }
            #expect(try! balances(gastos) == (try! balances(reordenados)))
        }
    }

    /// (6) Elemento neutro: un gasto de importe 0 no cambia los saldos.
    @Test func gastoDeImporteCeroEsNeutro() async {
        await propertyCheck(input: Escenario.gastos) { gastos in
            let antes = (try! balances(gastos)).filter { $0.value != 0 }
            let cero = Gasto(id: "cero", pagadoPor: MiembroId("m0"), importeMinor: 0,
                             reparto: .igual(entre: [MiembroId("m0"), MiembroId("m1")]))
            let despues = (try! balances(gastos + [cero])).filter { $0.value != 0 }
            #expect(antes == despues)
        }
    }

    /// (7) Aditividad: los saldos de `A ++ B` son la suma miembro a miembro de los
    /// saldos de `A` y de `B` por separado.
    @Test func aditividad() async {
        await propertyCheck(input: Escenario.gastos, Escenario.gastos) { a, b in
            let combinado = try! balances(a + b)
            let sa = try! balances(a)
            let sb = try! balances(b)
            var sumaManual = sa
            for (m, v) in sb { sumaManual[m, default: 0] += v }
            let claves = Set(combinado.keys).union(sumaManual.keys)
            for m in claves {
                #expect((combinado[m] ?? 0) == (sumaManual[m] ?? 0))
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
