// Los casos de uso de gastos, probados contra el adaptador en memoria. Estos tests
// ejercitan los flujos de los ADRs (idempotencia, conflicto por ETag, tombstone,
// autorización) sin DB ni HTTP.

import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Casos de uso de gastos")
struct CasosDeUsoTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan"), sara = MiembroId("sara")
    let trip = "trip-1"

    /// Monta un repo con `ana` e `ivan` como miembros del viaje.
    func nuevoEntorno() async -> (CasosDeUsoGastos, RepositorioEnMemoria) {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(ana, a: trip)
        await repo.anadirMiembro(ivan, a: trip)
        return (CasosDeUsoGastos(repo: repo, membresia: repo), repo)
    }

    func gasto(_ id: String, importe: Int64 = 3000) -> Gasto {
        Gasto(id: id, pagadoPor: ana, importeMinor: importe, reparto: .igual(entre: [ana, ivan]))
    }

    @Test func crearGastoValido() async throws {
        let (casos, _) = await nuevoEntorno()
        let r = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        guard case .creado = r else { Issue.record("esperaba creado, obtuve \(r)"); return }
    }

    /// Idempotencia: el mismo idempotencyKey no crea dos veces (ADR-0012).
    @Test func reintentoConMismaClaveNoDuplica() async throws {
        let (casos, repo) = await nuevoEntorno()
        let cmd = ComandoCrearGasto(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1")
        _ = try await casos.crear(cmd)
        let segundo = try await casos.crear(cmd)
        guard case .reproducido = segundo else { Issue.record("esperaba reproducido, obtuve \(segundo)"); return }
        let n = await repo.gastos(de: trip).count
        #expect(n == 1, "no debe haber duplicado")
    }

    /// Dedupe estructural: mismo id, distinta clave -> tampoco duplica.
    @Test func mismoIdDistintaClaveNoDuplica() async throws {
        let (casos, repo) = await nuevoEntorno()
        _ = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        let segundo = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ivan, idempotencyKey: "k2"))
        guard case .reproducido = segundo else { Issue.record("esperaba reproducido, obtuve \(segundo)"); return }
        #expect(await repo.gastos(de: trip).count == 1)
    }

    /// Todos los miembros pueden editar (ADR-0015 §15): Iván edita el gasto que
    /// creó Ana.
    @Test func cualquierMiembroPuedeEditar() async throws {
        let (casos, repo) = await nuevoEntorno()
        _ = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        let etag = try #require(await repo.gasto(id: "g1", en: trip)).etag
        let r = try await casos.editar(.init(tripId: trip, gasto: gasto("g1", importe: 5000),
                                             actor: ivan, ifMatch: etag, idempotencyKey: "k2"))
        guard case .actualizado = r else { Issue.record("esperaba actualizado, obtuve \(r)"); return }
    }

    /// Conflicto: editar con un ETag rancio da conflicto, no pisa (ADR-0013 §2).
    @Test func editarConEtagRancioDaConflicto() async throws {
        let (casos, repo) = await nuevoEntorno()
        _ = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        let etagViejo = try #require(await repo.gasto(id: "g1", en: trip)).etag
        // Ana edita primero (avanza el etag).
        _ = try await casos.editar(.init(tripId: trip, gasto: gasto("g1", importe: 4000),
                                        actor: ana, ifMatch: etagViejo, idempotencyKey: "k2"))
        // Iván edita con el etag viejo -> conflicto.
        let r = try await casos.editar(.init(tripId: trip, gasto: gasto("g1", importe: 9000),
                                            actor: ivan, ifMatch: etagViejo, idempotencyKey: "k3"))
        guard case .conflicto = r else { Issue.record("esperaba conflicto, obtuve \(r)"); return }
    }

    /// No-miembro: rechazo permanente (no un 4xx que congele la cola).
    @Test func noMiembroEsRechazado() async throws {
        let (casos, _) = await nuevoEntorno()
        let r = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: sara, idempotencyKey: "k1"))
        #expect(r == .rechazado(razon: "not_member"))
    }

    /// Viaje cerrado: rechazo permanente.
    @Test func viajeCerradoEsRechazado() async throws {
        let (casos, repo) = await nuevoEntorno()
        await repo.cerrarViaje(trip)
        let r = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        #expect(r == .rechazado(razon: "trip_closed"))
    }

    /// Gasto con reparto que no cuadra: rechazado como inválido, no se persiste.
    @Test func gastoInvalidoEsRechazado() async throws {
        let (casos, _) = await nuevoEntorno()
        let malo = Gasto(id: "g1", pagadoPor: ana, importeMinor: 1000,
                         reparto: .exacto([ana: 400, ivan: 400]))  // suman 800, no 1000
        let r = try await casos.crear(.init(tripId: trip, gasto: malo, actor: ana, idempotencyKey: "k1"))
        #expect(r == .rechazado(razon: "invalid_expense"))
    }

    /// Borrar es idempotente: reintentar un borrado ya hecho no es error.
    @Test func borrarEsIdempotente() async throws {
        let (casos, repo) = await nuevoEntorno()
        _ = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        let etag = try #require(await repo.gasto(id: "g1", en: trip)).etag
        let r1 = try await casos.eliminar(.init(tripId: trip, gastoId: "g1", actor: ana, ifMatch: etag, idempotencyKey: "k2"))
        #expect(r1 == .eliminado)
        // Reintento con otra clave: el gasto ya no está -> sigue siendo eliminado.
        let r2 = try await casos.eliminar(.init(tripId: trip, gastoId: "g1", actor: ana, ifMatch: etag, idempotencyKey: "k3"))
        #expect(r2 == .eliminado)
        #expect(await repo.gastos(de: trip).isEmpty)
    }
}
