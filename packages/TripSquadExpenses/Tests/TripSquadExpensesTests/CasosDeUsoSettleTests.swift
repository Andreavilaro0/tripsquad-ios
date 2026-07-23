import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Máquina de estados de :settle (ADR-0017)")
struct CasosDeUsoSettleTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func setup() async -> (RepositorioEnMemoria, CasosDeUsoSettle) {
        let r = RepositorioEnMemoria()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        await r.anadirMiembro(MiembroId("ivan"), a: "t1")
        return (r, CasosDeUsoSettle(repo: r, membresia: r))
    }
    func cmd(_ sid: String = "s1", from: String = "ivan", to: String = "ana",
             amount: Int64 = 2000, actor: String = "ivan") -> ComandoCrearPago {
        .init(tripId: "t1", settlementId: sid, from: MiembroId(from), to: MiembroId(to),
              transferIndex: 0, amountMinor: amount, actor: MiembroId(actor))
    }

    @Test func crearNacePendingYDaId() async throws {
        let (_, casos) = await setup()
        let res = try await casos.crearPagos([cmd()], ahora: t0)
        guard case .creado(let id) = res[0] else { Issue.record("esperaba creado"); return }
        #expect(!id.isEmpty)
    }

    @Test func crearReintentoMismaClaveEsDuplicado() async throws {
        let (_, casos) = await setup()
        _ = try await casos.crearPagos([cmd()], ahora: t0)
        let res = try await casos.crearPagos([cmd(amount: 5)], ahora: t0)  // otro importe, misma clave
        guard case .duplicado = res[0] else { Issue.record("esperaba duplicado"); return }
    }

    @Test func crearActorNoEsParteSeRechaza() async throws {
        let (r, casos) = await setup()
        await r.anadirMiembro(MiembroId("sara"), a: "t1")
        let res = try await casos.crearPagos([cmd(actor: "sara")], ahora: t0)  // sara ∉ {ivan,ana}
        #expect(res[0] == .rechazado(razon: "actor_not_party"))
    }

    @Test func crearParteNoMiembroSeRechaza() async throws {
        let (_, casos) = await setup()
        let res = try await casos.crearPagos([cmd(to: "nadie")], ahora: t0)  // 'nadie' no es miembro
        #expect(res[0] == .rechazado(razon: "payee_not_member"))
    }

    @Test func importeNoPositivoSeRechaza() async throws {
        let (_, casos) = await setup()
        #expect(try await casos.crearPagos([cmd(amount: 0)], ahora: t0)[0] == .rechazado(razon: "invalid_amount"))
    }

    @Test func contraparteConfirma() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        // ivan creó; ana (contraparte) confirma
        let r = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0)
        #expect(r == .ok)
    }

    @Test func creadorNoPuedeConfirmar() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        let r = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ivan"), ahora: t0)  // ivan = creador
        #expect(r == .noAutorizado)
    }

    @Test func creadorCancela() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        #expect(try await casos.cancelar(id: id, en: "t1", por: MiembroId("ivan"), ahora: t0) == .ok)
    }

    @Test func confirmarDosVecesEsIdempotenteNoError() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        _ = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0)
        // repetir la MISMA transición terminal → estadoInvalido (ya no es pending) NO es crash
        #expect(try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0) == .estadoInvalido)
    }

    @Test func rechazarConMotivo() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        #expect(try await casos.rechazar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0, motivo: "no recibí eso") == .ok)
    }

    @Test func pendingCaducadoNoSePuedeConfirmar() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        let futuro = t0.addingTimeInterval(31 * 24 * 3600)   // > 30 días
        #expect(try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: futuro) == .caducado)
    }

    @Test func soloConfirmadosCuentanParaSaldos() async throws {
        let (r, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        #expect(try await r.confirmados(de: "t1").isEmpty)     // pending no cuenta
        _ = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0)
        #expect(try await r.confirmados(de: "t1").count == 1)  // confirmed sí
    }
}
