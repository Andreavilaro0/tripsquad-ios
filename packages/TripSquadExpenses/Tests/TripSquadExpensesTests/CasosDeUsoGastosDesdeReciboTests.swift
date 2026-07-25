// Caso de uso `crearDesdeRecibo`: construye el Gasto (.exacto) desde un recibo
// itemizado y delega en `crear` (replay + auth + validación + persistencia).

import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Casos de uso de gastos desde recibo")
struct CasosDeUsoGastosDesdeReciboTests {

    struct Entorno {
        let casos: CasosDeUsoGastos
        let repo: RepositorioEnMemoria
        let a: MiembroId
        let b: MiembroId
    }

    /// Monta un repo con viaje `t1`, miembros `a` y `b`.
    func fixtureGastos(cerrado: Bool = false) async throws -> Entorno {
        let repo = RepositorioEnMemoria()
        let a = MiembroId("a"), b = MiembroId("b")
        await repo.anadirMiembro(a, a: "t1")
        await repo.anadirMiembro(b, a: "t1")
        if cerrado { await repo.cerrarViaje("t1") }
        return Entorno(casos: CasosDeUsoGastos(repo: repo, membresia: repo), repo: repo, a: a, b: b)
    }

    @Test func creaGastoExactoDesdeRecibo() async throws {
        let f = try await fixtureGastos()
        let r = try await f.casos.crearDesdeRecibo(
            tripId: "t1", gastoId: "g1", pagadoPor: f.a,
            items: [ItemRecibo(importeMinor: 750, sharers: [f.a]),
                    ItemRecibo(importeMinor: 250, sharers: [f.b])],
            impuestosMinor: 100, propinaMinor: 0, actor: f.a, idempotencyKey: "k1")
        guard case .creado = r else { Issue.record("esperaba creado, fue \(r)"); return }
        // el gasto persistido reparte 825/275 (75/25 de impuesto proporcional)
        let g = try await f.repo.gasto(id: "g1", en: "t1")
        #expect(g?.gasto.importeMinor == 1100)
        #expect(g?.gasto.reparto == .exacto([f.a: 825, f.b: 275]))
    }

    @Test func noMiembroEsRechazado() async throws {
        let f = try await fixtureGastos()
        let r = try await f.casos.crearDesdeRecibo(
            tripId: "t1", gastoId: "g2", pagadoPor: MiembroId("ext"),
            items: [ItemRecibo(importeMinor: 100, sharers: [MiembroId("ext")])],
            impuestosMinor: 0, propinaMinor: 0, actor: MiembroId("ext"), idempotencyKey: "k2")
        #expect(r == .rechazado(razon: "not_member"))
    }

    @Test func viajeCerradoEsRechazado() async throws {
        let f = try await fixtureGastos(cerrado: true)
        let r = try await f.casos.crearDesdeRecibo(
            tripId: "t1", gastoId: "g3", pagadoPor: f.a,
            items: [ItemRecibo(importeMinor: 100, sharers: [f.a])],
            impuestosMinor: 0, propinaMinor: 0, actor: f.a, idempotencyKey: "k3")
        #expect(r == .rechazado(razon: "trip_closed"))
    }

    @Test func reciboInvalidoEsRechazado() async throws {   // ítem sin sharers
        let f = try await fixtureGastos()
        let r = try await f.casos.crearDesdeRecibo(
            tripId: "t1", gastoId: "g4", pagadoPor: f.a,
            items: [ItemRecibo(importeMinor: 100, sharers: [])],
            impuestosMinor: 0, propinaMinor: 0, actor: f.a, idempotencyKey: "k4")
        #expect(r == .rechazado(razon: "invalid_receipt"))
    }

    @Test func replayDevuelveReproducido() async throws {
        let f = try await fixtureGastos()
        let mk = { try await f.casos.crearDesdeRecibo(
            tripId: "t1", gastoId: "g5", pagadoPor: f.a,
            items: [ItemRecibo(importeMinor: 100, sharers: [f.a])],
            impuestosMinor: 0, propinaMinor: 0, actor: f.a, idempotencyKey: "k5") }
        _ = try await mk()
        let r2 = try await mk()
        guard case .reproducido = r2 else { Issue.record("esperaba reproducido"); return }
    }
}
