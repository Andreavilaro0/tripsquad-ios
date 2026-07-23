import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Settlement — clave determinista")
struct SettlementTests {
    @Test func idEstableParaLosMismosCampos() {
        let a = Settlement(settlementId: "s1", tripId: "t1", from: MiembroId("ana"), to: MiembroId("ivan"), transferIndex: 0, amountMinor: 2000)
        let b = Settlement(settlementId: "s1", tripId: "t1", from: MiembroId("ana"), to: MiembroId("ivan"), transferIndex: 0, amountMinor: 9999)
        // El importe NO entra en la clave: dos registros del mismo pago colisionan.
        #expect(a.idDeterminista == b.idDeterminista)
    }
    @Test func idDistintoPorTransferIndex() {
        let a = Settlement(settlementId: "s1", tripId: "t1", from: MiembroId("ana"), to: MiembroId("ivan"), transferIndex: 0, amountMinor: 2000)
        let b = Settlement(settlementId: "s1", tripId: "t1", from: MiembroId("ana"), to: MiembroId("ivan"), transferIndex: 1, amountMinor: 2000)
        #expect(a.idDeterminista != b.idDeterminista)
    }
}
