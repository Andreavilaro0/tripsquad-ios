import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Registrar pago (ADR-0016)")
struct CasosDeUsoSettleTests {
    func repo() -> RepositorioEnMemoria { RepositorioEnMemoria() }

    @Test func registraUnPagoDeMiembro() async throws {
        let r = repo()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        await r.anadirMiembro(MiembroId("ivan"), a: "t1")
        let casos = CasosDeUsoSettle(repo: r, membresia: r)
        let res = try await casos.registrarPago(.init(tripId: "t1", settlementId: "s1", from: MiembroId("ivan"), to: MiembroId("ana"), transferIndex: 0, amountMinor: 2000, actor: MiembroId("ivan")))
        #expect(res == .registrado)
    }

    @Test func reintentoMismoSettlementIdEsDuplicado() async throws {
        let r = repo()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        await r.anadirMiembro(MiembroId("ivan"), a: "t1")
        let casos = CasosDeUsoSettle(repo: r, membresia: r)
        let cmd = ComandoRegistrarPago(tripId: "t1", settlementId: "s1", from: MiembroId("ivan"), to: MiembroId("ana"), transferIndex: 0, amountMinor: 2000, actor: MiembroId("ivan"))
        _ = try await casos.registrarPago(cmd)
        let segundo = try await casos.registrarPago(cmd)
        #expect(segundo == .duplicado)
    }

    @Test func noMiembroSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        let casos = CasosDeUsoSettle(repo: r, membresia: r)
        let res = try await casos.registrarPago(.init(tripId: "t1", settlementId: "s1", from: MiembroId("sara"), to: MiembroId("ana"), transferIndex: 0, amountMinor: 2000, actor: MiembroId("sara")))
        #expect(res == .rechazado(razon: "not_member"))
    }

    @Test func importeNoPositivoSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        await r.anadirMiembro(MiembroId("ivan"), a: "t1")
        let casos = CasosDeUsoSettle(repo: r, membresia: r)
        let res = try await casos.registrarPago(.init(tripId: "t1", settlementId: "s1", from: MiembroId("ivan"), to: MiembroId("ana"), transferIndex: 0, amountMinor: 0, actor: MiembroId("ivan")))
        #expect(res == .rechazado(razon: "invalid_amount"))
    }
}
