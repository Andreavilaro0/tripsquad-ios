// Tests de `CasosDeUsoReserva` (wedge "quién ya reservó"). El foco es la
// AUTORIZACIÓN y las reglas de `definir`/`marcar` — mismo espíritu que
// `CasosDeUsoItinerarioTests`.
//
// El fixture reutiliza el patrón de montaje de `CasosDeUsoItinerarioTests`:
// crea el viaje directamente en `RepositorioEnMemoria` (mismo repo que usa
// `CasosDeUsoViaje.crear` por debajo — `crearViaje(id:...)` deja al creador
// como `.owner` en el ÚNICO almacén real de rol/membresía), añade miembros
// con `anadirMiembro` (igual que el paso de sincronización de
// `soloCreadorOOwnerEditanYBorran`), y siembra la actividad "act1" con
// `ItinerarioRepositorio.crear` directamente para fijar su id de forma
// determinista (los tests del brief referencian "act1" literal).

import Testing
import Foundation
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Reserva: quién ya reservó (wedge)")
struct CasosDeUsoReservaTests {

    private struct Fixture {
        let casos: CasosDeUsoReserva
        let repo: RepositorioEnMemoria
        let a: MiembroId   // owner del viaje
        let b: MiembroId   // miembro, creador de act1
        let c: MiembroId   // miembro, ni creador ni owner
    }

    private let ahora = Date(timeIntervalSince1970: 1_700_000_000)

    /// Monta el viaje "t1": owner `a`, miembro `b` (creador de "act1"),
    /// miembro `c` (ni creador ni owner). `cerrado: true` cierra el viaje
    /// DESPUÉS de sembrar la actividad, igual que
    /// `crearYEditarEnViajeCerradoSeRechazan` en itinerario.
    private func fixture(cerrado: Bool = false) async throws -> Fixture {
        let r = RepositorioEnMemoria()
        let a = MiembroId("a"), b = MiembroId("b"), c = MiembroId("c")
        _ = await r.crearViaje(id: "t1", name: "Roma", baseCurrency: "EUR", creador: a, ahora: ahora)
        await r.anadirMiembro(b, a: "t1")
        await r.anadirMiembro(c, a: "t1")
        await r.crear(ActividadItinerario(id: "act1", tripId: "t1", title: "Vuelo a Roma", day: "2026-08-02", createdBy: b), ahora: ahora)
        if cerrado { await r.cerrarViaje("t1") }
        let casos = CasosDeUsoReserva(repo: r, itinerario: r, membresia: r, viajes: r)
        return Fixture(casos: casos, repo: r, a: a, b: b, c: c)
    }

    @Test func definirComoCreadorCreaReservablePendiente() async throws {
        let f = try await fixture()              // owner a, miembro b, actividad act1 creada por b
        let r = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a, f.b]), actor: f.b, ahora: Date())
        #expect(try r.get().mode == .cadaUnoElSuyo(estados: [f.a: .pendiente, f.b: .pendiente]))
    }

    @Test func definirPorNoCreadorNoOwnerEsNoAutorizado() async throws {
        let f = try await fixture()              // c es miembro pero ni creador ni owner
        let r = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a]), actor: f.c, ahora: Date())
        #expect(r == .failure(.noAutorizado))
    }

    @Test func definirConParticipanteNoMiembroEsReglaViolada() async throws {
        let f = try await fixture()
        let r = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [MiembroId("ext")]), actor: f.b, ahora: Date())
        #expect(r == .failure(.reglaViolada("participante_no_miembro")))
    }

    @Test func definirActividadInexistenteEsNoAutorizado() async throws {   // sin fuga de existencia
        let f = try await fixture()
        let r = try await f.casos.definir(tripId: "t1", activityId: "noexiste", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a]), actor: f.a, ahora: Date())
        #expect(r == .failure(.noAutorizado))
    }

    @Test func definirEnViajeCerradoEsViajeCerrado() async throws {
        let f = try await fixture(cerrado: true)
        let r = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a]), actor: f.a, ahora: Date())
        #expect(r == .failure(.viajeCerrado))
    }

    @Test func marcarPropioEstadoOk() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a, f.b]), actor: f.b, ahora: Date())
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.b,
            estado: .reservado, actor: f.b, ahora: Date())
        #expect(try r.get().mode == .cadaUnoElSuyo(estados: [f.a: .pendiente, f.b: .reservado]))
    }

    @Test func marcarEstadoAjenoSinSerOwnerEsNoAutorizado() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a, f.b]), actor: f.b, ahora: Date())
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.a,
            estado: .reservado, actor: f.b, ahora: Date())   // b intenta marcar a a
        #expect(r == .failure(.noAutorizado))
    }

    @Test func ownerPuedeMarcarEstadoAjeno() async throws {
        let f = try await fixture()   // a = owner
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a, f.b]), actor: f.b, ahora: Date())
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.b,
            estado: .reservado, actor: f.a, ahora: Date())   // owner marca a b
        #expect(try r.get().mode == .cadaUnoElSuyo(estados: [f.a: .pendiente, f.b: .reservado]))
    }

    @Test func marcarMiembroNoIncluidoEsReglaViolada() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a]), actor: f.a, ahora: Date())   // b NO incluido
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.b,
            estado: .reservado, actor: f.a, ahora: Date())
        #expect(r == .failure(.reglaViolada("miembro_no_incluido")))
    }

    @Test func tableroSoloMiembros() async throws {
        let f = try await fixture()
        let r = try await f.casos.tablero(tripId: "t1", actor: MiembroId("ext"))
        #expect(r == .failure(.noAutorizado))
    }
}
