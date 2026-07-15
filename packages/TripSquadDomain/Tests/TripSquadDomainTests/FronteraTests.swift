// Frontera del dinero y errores de entrada (ADR-0011 §2; ADR-0015 §4).

import Testing
@testable import TripSquadDomain

@Suite("Dinero — frontera decimal")
struct DineroTests {

    @Test func parseoEur() {
        #expect(try! Dinero.minorUnits(desde: "10.99", divisa: .eur) == 1099)
        #expect(try! Dinero.minorUnits(desde: "0", divisa: .eur) == 0)
        #expect(try! Dinero.minorUnits(desde: "1000", divisa: .eur) == 100_000)
    }

    /// El motivo de todo: 0,1 + 0,2 debe dar exactamente 0,3 en céntimos. Con
    /// `Double` sería 0.30000000000000004; con `Int64` es 30 == 30.
    @Test func sinErrorBinario() {
        let a = try! Dinero.minorUnits(desde: "0.1", divisa: .eur)
        let b = try! Dinero.minorUnits(desde: "0.2", divisa: .eur)
        let c = try! Dinero.minorUnits(desde: "0.3", divisa: .eur)
        #expect(a == 10)
        #expect(b == 20)
        #expect(a + b == c)
    }

    @Test func masDecimalesDeLosPermitidosEsError() {
        #expect(throws: DineroError.formatoInvalido) {
            try Dinero.minorUnits(desde: "10.999", divisa: .eur)
        }
    }

    @Test func formatoInvalidoEsError() {
        #expect(throws: DineroError.formatoInvalido) {
            try Dinero.minorUnits(desde: "diez", divisa: .eur)
        }
    }

    @Test func formateo() {
        #expect(Dinero.decimalString(1099, divisa: .eur) == "10.99")
        #expect(Dinero.decimalString(5, divisa: .eur) == "0.05")
        #expect(Dinero.decimalString(-500, divisa: .eur) == "-5.00")
        #expect(Dinero.decimalString(1000, divisa: .jpy) == "1000")
    }
}

@Suite("Entradas inválidas — el motor es total")
struct ErroresTests {

    let m1 = MiembroId("m1"), m2 = MiembroId("m2")

    @Test func importeNegativo() {
        let g = Gasto(id: "g", pagadoPor: m1, importeMinor: -1, reparto: .igual(entre: [m1, m2]))
        #expect(throws: DomainError.importeNegativo) { try cuotas(de: g) }
    }

    @Test func cuotasQueNoCuadran() {
        let g = Gasto(id: "g", pagadoPor: m1, importeMinor: 1000,
                      reparto: .exacto([m1: 400, m2: 400]))  // suman 800, no 1000
        #expect(throws: DomainError.cuotasNoCuadran) { try cuotas(de: g) }
    }

    @Test func sinParticipantes() {
        let g = Gasto(id: "g", pagadoPor: m1, importeMinor: 100, reparto: .igual(entre: []))
        #expect(throws: DomainError.sinParticipantes) { try cuotas(de: g) }
    }

    @Test func miembroDuplicado() {
        let g = Gasto(id: "g", pagadoPor: m1, importeMinor: 100, reparto: .igual(entre: [m1, m1]))
        #expect(throws: DomainError.miembroDuplicado) { try cuotas(de: g) }
    }

    @Test func pesoInvalido() {
        let g = Gasto(id: "g", pagadoPor: m1, importeMinor: 100, reparto: .porPeso([m1: 0, m2: 3]))
        #expect(throws: DomainError.pesoInvalido) { try cuotas(de: g) }
    }

    /// Overflow del reparto por peso (hallazgo P0 de la voz externa Gemini): con
    /// `importe * peso` en Int64 esto crasheaba; con Int128 intermedio, no. El
    /// producto `10^9 · 10^9` desborda Int64 (~9.2·10^18) por rozar el límite.
    @Test func repartoPorPesoNoDesborda() {
        let importe: Int64 = 1_000_000_000            // 10^9 céntimos
        let g = Gasto(id: "g", pagadoPor: m1, importeMinor: importe,
                      reparto: .porPeso([m1: 1_000_000_000, m2: 1_000_000_000]))  // pesos 10^9
        let c = try! cuotas(de: g)
        #expect(c.values.reduce(0, +) == importe)      // conservación exacta
        #expect(c[m1] == 500_000_000)
        #expect(c[m2] == 500_000_000)
    }
}
