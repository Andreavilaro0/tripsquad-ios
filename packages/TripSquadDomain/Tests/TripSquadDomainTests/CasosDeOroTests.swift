// Casos de oro: ejemplos concretos y célebres del dominio (ADR-0011 §6, §7).
// Números calculados a mano; si el motor cambia, estos tests lo cazan.

import Testing
@testable import TripSquadDomain

@Suite("Casos de oro")
struct CasosDeOroTests {

    let m0 = MiembroId("m0"), m1 = MiembroId("m1"), m2 = MiembroId("m2")
    let m3 = MiembroId("m3"), m4 = MiembroId("m4")

    /// 10 € entre 3 = 334 + 333 + 333. El pagador (m1) absorbe el céntimo.
    @Test func diezEurosEntreTres() {
        let g = Gasto(id: "g", pagadoPor: m1, importeMinor: 1000,
                      reparto: .igual(entre: [m1, m2, m3]))
        let c = try! cuotas(de: g)
        #expect(c[m1] == 334)
        #expect(c[m2] == 333)
        #expect(c[m3] == 333)
        #expect(c.values.reduce(0, +) == 1000)
        // Saldos: m1 pagó 1000, consume 334 -> +666; m2 y m3 -333.
        let b = try! balances([g])
        #expect(b[m1] == 666)
        #expect(b[m2] == -333)
        #expect(b[m3] == -333)
    }

    /// 1 céntimo entre 5, lo paga m0: el céntimo se lo asigna a m0 (pagador), que
    /// además lo pagó -> todos quedan a cero.
    @Test func unCentimoEntreCinco() {
        let g = Gasto(id: "g", pagadoPor: m0, importeMinor: 1,
                      reparto: .igual(entre: [m0, m1, m2, m3, m4]))
        let c = try! cuotas(de: g)
        #expect(c[m0] == 1)
        #expect(c.values.reduce(0, +) == 1)
        let b = try! balances([g])
        #expect(b.values.allSatisfy { $0 == 0 })
    }

    /// Grupo de una persona: paga y consume todo -> saldo 0, nada que liquidar.
    @Test func grupoDeUnaPersona() {
        let g = Gasto(id: "g", pagadoPor: m0, importeMinor: 500, reparto: .igual(entre: [m0]))
        let b = try! balances([g])
        #expect(b[m0] == 0)
        #expect(liquidar(b).isEmpty)
    }

    /// Pagador que NO participa: paga 900 por m1, m2, m3 (300 c/u). El resto de un
    /// importe con sobrante va al primer participante por id, no al pagador ausente.
    @Test func pagadorQueNoParticipa() {
        let g = Gasto(id: "g", pagadoPor: m0, importeMinor: 1000,
                      reparto: .igual(entre: [m1, m2, m3]))
        let c = try! cuotas(de: g)
        #expect(c[m0] == nil)          // el pagador no participa: no tiene cuota
        #expect(c[m1] == 334)          // sobrante al primer participante por id
        #expect(c[m2] == 333)
        #expect(c[m3] == 333)
        let b = try! balances([g])
        #expect(b[m0] == 1000)
        #expect(b.values.reduce(0, +) == 0)
    }

    /// JPY es zero-decimal: 1000 ¥ son 1000 unidades menores, sin punto decimal.
    @Test func jpyZeroDecimal() {
        #expect(try! Dinero.minorUnits(desde: "1000", divisa: .jpy) == 1000)
        #expect(Dinero.decimalString(1000, divisa: .jpy) == "1000")
    }

    /// El contraejemplo del greedy (ADR-0011 §1): dos pasadas lo saldan en 4
    /// transferencias; el greedy solo emitiría 6. `liquidar` devuelve la mejor.
    @Test func contraejemploDelGreedy() {
        let saldos: [MiembroId: Int64] = [
            MiembroId("a"): -14, MiembroId("b"): -13, MiembroId("c"): 14,
            MiembroId("d"): 13, MiembroId("e"): 7, MiembroId("f"): 11,
            MiembroId("g"): -18,
        ]
        let ts = liquidar(saldos)
        #expect(ts.count <= 4, "esperaba <=4 (dos pasadas), obtuve \(ts.count)")
        // Y sigue siendo correcto: deja todo a cero.
        #expect(aplicar(ts, a: saldos).values.allSatisfy { $0 == 0 })
    }
}
