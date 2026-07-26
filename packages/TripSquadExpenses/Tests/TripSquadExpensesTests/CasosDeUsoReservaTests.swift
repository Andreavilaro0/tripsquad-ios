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
        let fake = EstructuradorConfirmacionFake(datos: DatosConfirmacion(tipo: .vuelo, fechaISO: nil, numeroConfirmacion: nil, proveedor: nil))
        let casos = CasosDeUsoReserva(repo: r, itinerario: r, membresia: r, viajes: r, estructurador: fake)
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

    // MARK: - unoParaTodos (fix round 1: cobertura ausente)

    @Test func definirUnoParaTodosComoCreadorOk() async throws {
        let f = try await fixture()
        let r = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .hotel,
            modo: .unoParaTodos(responsable: f.b), actor: f.b, ahora: Date())
        #expect(try r.get().mode == .unoParaTodos(responsable: f.b, estado: .pendiente))
    }

    @Test func definirUnoParaTodosConResponsableNoMiembroEsReglaViolada() async throws {
        let f = try await fixture()
        let r = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .hotel,
            modo: .unoParaTodos(responsable: MiembroId("ext")), actor: f.b, ahora: Date())
        #expect(r == .failure(.reglaViolada("responsable_no_miembro")))
    }

    @Test func marcarUnoParaTodosPorResponsableOk() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .hotel,
            modo: .unoParaTodos(responsable: f.b), actor: f.b, ahora: Date())
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: nil,
            estado: .reservado, actor: f.b, ahora: Date())
        #expect(try r.get().mode == .unoParaTodos(responsable: f.b, estado: .reservado))
    }

    @Test func marcarUnoParaTodosPorNoResponsableNoOwnerEsNoAutorizado() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .hotel,
            modo: .unoParaTodos(responsable: f.b), actor: f.b, ahora: Date())
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: nil,
            estado: .reservado, actor: f.c, ahora: Date())   // c ni responsable ni owner
        #expect(r == .failure(.noAutorizado))
    }

    @Test func ownerMarcaUnoParaTodos() async throws {
        let f = try await fixture()   // a = owner, b = responsable
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .hotel,
            modo: .unoParaTodos(responsable: f.b), actor: f.b, ahora: Date())
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: nil,
            estado: .reservado, actor: f.a, ahora: Date())
        #expect(try r.get().mode == .unoParaTodos(responsable: f.b, estado: .reservado))
    }

    @Test func marcarUnoParaTodosConMemberIdSobraEsReglaViolada() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .hotel,
            modo: .unoParaTodos(responsable: f.b), actor: f.b, ahora: Date())
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.b,
            estado: .reservado, actor: f.b, ahora: Date())
        #expect(r == .failure(.reglaViolada("member_id_sobra")))
    }

    /// ADR-0024 / spec: si el responsable de un `unoParaTodos` fue expulsado,
    /// `quitarMiembro` deja `responsable = nil` (ver
    /// `RepositorioReservaEnMemoriaTests.expulsarLimpiaEstadoDeReserva`). Marcar esa
    /// reserva sin responsable debe rechazarse con `reglaViolada("sin_responsable")`
    /// (422 "reasignar primero"), NUNCA `.noAutorizado` — ni siquiera para el owner,
    /// porque el guard corre ANTES del gate de autorización (mismo resultado para
    /// owner y no-owner).
    @Test func marcarUnoParaTodosSinResponsableEsReglaViolada() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .hotel,
            modo: .unoParaTodos(responsable: f.b), actor: f.b, ahora: Date())
        try await f.repo.quitarMiembro(f.b, de: "t1", ahora: Date())   // expulsa al responsable

        let porOwner = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: nil,
            estado: .reservado, actor: f.a, ahora: Date())
        #expect(porOwner == .failure(.reglaViolada("sin_responsable")))

        let porNoOwner = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: nil,
            estado: .reservado, actor: f.c, ahora: Date())
        #expect(porNoOwner == .failure(.reglaViolada("sin_responsable")))
    }

    // MARK: - quitar (fix round 1: cobertura ausente)

    @Test func quitarPorCreadorOk() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.b]), actor: f.b, ahora: Date())
        let r = try await f.casos.quitar(tripId: "t1", activityId: "act1", actor: f.b, ahora: Date())
        guard case .success = r else { Issue.record("esperaba quitar exitoso (creador)"); return }
        let tras = try await f.casos.tablero(tripId: "t1", actor: f.a)
        #expect(try tras.get().isEmpty)
    }

    @Test func quitarPorNoCreadorNoOwnerEsNoAutorizado() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.b]), actor: f.b, ahora: Date())
        let r = try await f.casos.quitar(tripId: "t1", activityId: "act1", actor: f.c, ahora: Date())
        guard case .failure(let error) = r else { Issue.record("esperaba failure"); return }
        #expect(error == .noAutorizado)
    }

    // MARK: - marcar: viaje cerrado / reserva inexistente (fix round 1: cobertura ausente)

    @Test func marcarEnViajeCerradoEsViajeCerrado() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a, f.b]), actor: f.b, ahora: Date())
        await f.repo.cerrarViaje("t1")
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.b,
            estado: .reservado, actor: f.b, ahora: Date())
        #expect(r == .failure(.viajeCerrado))
    }

    @Test func marcarReservaInexistenteEsNoAutorizado() async throws {   // sin fuga de existencia
        let f = try await fixture()
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.b,
            estado: .reservado, actor: f.b, ahora: Date())
        #expect(r == .failure(.noAutorizado))
    }
}
