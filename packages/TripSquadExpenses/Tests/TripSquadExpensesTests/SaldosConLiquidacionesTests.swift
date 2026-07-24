import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Saldos con liquidaciones confirmadas")
struct SaldosConLiquidacionesTests {
    func settlement(_ from: String, _ to: String, _ amount: Int64) -> Settlement {
        Settlement(settlementId: "s", tripId: "t1", from: MiembroId(from), to: MiembroId(to),
                   transferIndex: 0, amountMinor: amount, createdBy: MiembroId(from),
                   expiresAt: Date(timeIntervalSince1970: 0), status: .confirmed)
    }
    @Test func unPagoConfirmadoSaldaLaDeuda() throws {
        // Iván debe 2000 a Ana (cena 4000 pagada por Ana, split 2000/2000).
        let gasto = Gasto(id: "g1", pagadoPor: MiembroId("ana"), importeMinor: 4000,
                          reparto: .igual(entre: [MiembroId("ana"), MiembroId("ivan")]))
        let base = try balances([gasto])
        #expect(base[MiembroId("ivan")] == -2000)
        #expect(base[MiembroId("ana")] == 2000)
        let neto = try balancesConLiquidaciones([gasto], confirmados: [settlement("ivan", "ana", 2000)])
        #expect(neto[MiembroId("ivan")] == 0)
        #expect(neto[MiembroId("ana")] == 0)
    }
    @Test func pagoParcialDejaResto() throws {
        let gasto = Gasto(id: "g1", pagadoPor: MiembroId("ana"), importeMinor: 4000,
                          reparto: .igual(entre: [MiembroId("ana"), MiembroId("ivan")]))
        let neto = try balancesConLiquidaciones([gasto], confirmados: [settlement("ivan", "ana", 500)])
        #expect(neto[MiembroId("ivan")] == -1500)
        #expect(neto[MiembroId("ana")] == 1500)
    }
}
