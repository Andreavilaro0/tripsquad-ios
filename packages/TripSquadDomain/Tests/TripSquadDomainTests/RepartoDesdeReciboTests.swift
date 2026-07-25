import Testing
import TripSquadDomain

@Suite struct RepartoDesdeReciboTests {
    let a = MiembroId("a"), b = MiembroId("b"), c = MiembroId("c")

    // Suma == Σ ítems + impuestos + propina (conservación), vía `cuotas`.
    func exacto(_ r: Reparto) throws -> [MiembroId: Int64] {
        guard case .exacto(let m) = r else { Issue.record("no exacto"); return [:] }
        return m
    }

    @Test func itemsPropiosSinImpuestos() throws {
        // a: 1000, b: 500. Sin impuestos.
        let r = try repartoDesdeRecibo(items: [
            ItemRecibo(importeMinor: 1000, sharers: [a]),
            ItemRecibo(importeMinor: 500, sharers: [b]),
        ], impuestosMinor: 0, propinaMinor: 0)
        #expect(try exacto(r) == [a: 1000, b: 500])
    }

    @Test func itemCompartidoCentimoSobranteAlMiembroMenor() throws {
        // 1001 compartido entre a,b -> 501/500, el sobrante al menor por id (a).
        let r = try repartoDesdeRecibo(items: [
            ItemRecibo(importeMinor: 1001, sharers: [b, a]),
        ], impuestosMinor: 0, propinaMinor: 0)
        #expect(try exacto(r) == [a: 501, b: 500])
    }

    @Test func impuestosProporcionalAlSubtotal() throws {
        // subtotales a:1000, b:0? no. a:750, b:250 (items). Impuestos 100 -> 75/25.
        let r = try repartoDesdeRecibo(items: [
            ItemRecibo(importeMinor: 750, sharers: [a]),
            ItemRecibo(importeMinor: 250, sharers: [b]),
        ], impuestosMinor: 80, propinaMinor: 20)   // 100 total, 75/25
        #expect(try exacto(r) == [a: 825, b: 275])
    }

    @Test func unaSolaPersona() throws {
        let r = try repartoDesdeRecibo(items: [ItemRecibo(importeMinor: 900, sharers: [a])],
                                       impuestosMinor: 100, propinaMinor: 0)
        #expect(try exacto(r) == [a: 1000])
    }

    @Test func impuestoCero() throws {
        let r = try repartoDesdeRecibo(items: [
            ItemRecibo(importeMinor: 300, sharers: [a]),
            ItemRecibo(importeMinor: 300, sharers: [b, c]),  // 150 c/u
        ], impuestosMinor: 0, propinaMinor: 0)
        #expect(try exacto(r) == [a: 300, b: 150, c: 150])
    }

    @Test func itemSinSharersLanza() throws {
        #expect(throws: DomainError.sinParticipantes) {
            _ = try repartoDesdeRecibo(items: [ItemRecibo(importeMinor: 100, sharers: [])],
                                       impuestosMinor: 0, propinaMinor: 0)
        }
    }

    @Test func importeNegativoLanza() throws {
        #expect(throws: DomainError.importeNegativo) {
            _ = try repartoDesdeRecibo(items: [ItemRecibo(importeMinor: -5, sharers: [a])],
                                       impuestosMinor: 0, propinaMinor: 0)
        }
    }

    @Test func sumaConservaViaCuotas() throws {   // el .exacto cuadra con el importe derivado
        let r = try repartoDesdeRecibo(items: [
            ItemRecibo(importeMinor: 733, sharers: [a, b, c]),   // 245/244/244
        ], impuestosMinor: 67, propinaMinor: 0)
        let m = try exacto(r)
        let importe: Int64 = 733 + 67
        let g = Gasto(id: "g", pagadoPor: a, importeMinor: importe, reparto: r)
        #expect(try cuotas(de: g) == m)   // no lanza cuotasNoCuadran
        #expect(m.values.reduce(0, +) == importe)
    }
}
