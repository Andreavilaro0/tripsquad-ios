import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Settlement — clave natural y estados")
struct SettlementTests {
    func s(_ trip: String = "t1", _ sid: String = "s1", from: String = "ana", to: String = "ivan", idx: Int = 0) -> Settlement {
        Settlement(settlementId: sid, tripId: trip, from: MiembroId(from), to: MiembroId(to),
                   transferIndex: idx, amountMinor: 2000, createdBy: MiembroId(from),
                   expiresAt: Date(timeIntervalSince1970: 0))
    }

    @Test func naceEnPending() {
        #expect(s().status == .pending)
    }

    @Test func claveIgnoraImporteYEstado() {
        let a = s()
        let b = Settlement(settlementId: "s1", tripId: "t1", from: MiembroId("ana"), to: MiembroId("ivan"),
                           transferIndex: 0, amountMinor: 9999, createdBy: MiembroId("ana"),
                           expiresAt: Date(timeIntervalSince1970: 0))
        #expect(a.clave == b.clave)   // el importe no entra en la clave
    }

    @Test func claveDistinguePorTripId() {
        // Fix B: dos viajes con el mismo settlementId NO colisionan.
        #expect(s("t1").clave != s("t2").clave)
    }

    @Test func claveDistinguePorTransferIndex() {
        #expect(s(idx: 0).clave != s(idx: 1).clave)
    }
}
