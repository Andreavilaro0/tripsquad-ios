// Tests de `CasosDeUsoReserva.registrarConfirmacion` (dy5 "confirmaciones →
// auto-marca el wedge", spec docs/superpowers/specs/2026-07-25-dy5-confirmaciones-design.md).
// Reusa el patrón de fixture de `CasosDeUsoReservaTests` (siembra el viaje/
// actividad directamente en `RepositorioEnMemoria`), añadiendo un reservable
// `cadaUnoElSuyo([a, b])` ya definido en "act1" y un `EstructuradorConfirmacionFake`
// inyectado.

import Testing
import Foundation
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Reserva: registrarConfirmacion (dy5)")
struct RegistrarConfirmacionTests {

    private struct Fixture {
        let casos: CasosDeUsoReserva
        let repo: RepositorioEnMemoria
        let fake: EstructuradorConfirmacionFake
        let a: MiembroId   // owner del viaje, participante del reservable
        let b: MiembroId   // miembro, participante del reservable / responsable (unoParaTodos)
        let c: MiembroId   // miembro, ni responsable ni owner (solo usado en los fixtures unoParaTodos)
    }

    private let ahora = Date(timeIntervalSince1970: 1_700_000_000)

    /// Monta el viaje "t1": owner `a`, miembro `b`, actividad "act1"
    /// (creada por `a`), con un reservable `cadaUnoElSuyo([a, b])` ya
    /// definido (ambos `.pendiente`). El `EstructuradorConfirmacionFake`
    /// devuelve unos `DatosConfirmacion` fijos (nº "ABC123") salvo que el
    /// texto contenga "__ILEGIBLE__" (lanza `ErrorEstructurador.ilegible`).
    private func fixtureConReservable() async throws -> Fixture {
        let r = RepositorioEnMemoria()
        let a = MiembroId("a"), b = MiembroId("b"), c = MiembroId("c")
        _ = await r.crearViaje(id: "t1", name: "Roma", baseCurrency: "EUR", creador: a, ahora: ahora)
        await r.anadirMiembro(b, a: "t1")
        await r.anadirMiembro(c, a: "t1")
        await r.crear(ActividadItinerario(id: "act1", tripId: "t1", title: "Vuelo a Roma", day: "2026-08-02", createdBy: a), ahora: ahora)
        let fake = EstructuradorConfirmacionFake(datos: DatosConfirmacion(
            tipo: .vuelo, fechaISO: "2026-08-02", numeroConfirmacion: "ABC123", proveedor: "TAP"))
        let casos = CasosDeUsoReserva(repo: r, itinerario: r, membresia: r, viajes: r, estructurador: fake)
        _ = try await casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [a, b]), actor: a, ahora: ahora)
        return Fixture(casos: casos, repo: r, fake: fake, a: a, b: b, c: c)
    }

    /// Igual que `fixtureConReservable`, pero el reservable en "act1" es
    /// `unoParaTodos(responsable: b)` (fix round 1: cobertura ausente para
    /// este modo en `registrarConfirmacion`). `c` es miembro del viaje pero
    /// ni responsable ni owner — para probar el camino `noAutorizado`.
    private func fixtureUnoParaTodos() async throws -> Fixture {
        let r = RepositorioEnMemoria()
        let a = MiembroId("a"), b = MiembroId("b"), c = MiembroId("c")
        _ = await r.crearViaje(id: "t1", name: "Roma", baseCurrency: "EUR", creador: a, ahora: ahora)
        await r.anadirMiembro(b, a: "t1")
        await r.anadirMiembro(c, a: "t1")
        await r.crear(ActividadItinerario(id: "act1", tripId: "t1", title: "Hotel Roma", day: "2026-08-02", createdBy: a), ahora: ahora)
        let fake = EstructuradorConfirmacionFake(datos: DatosConfirmacion(
            tipo: .hotel, fechaISO: "2026-08-02", numeroConfirmacion: "XYZ789", proveedor: "Booking"))
        let casos = CasosDeUsoReserva(repo: r, itinerario: r, membresia: r, viajes: r, estructurador: fake)
        _ = try await casos.definir(tripId: "t1", activityId: "act1", kind: .hotel,
            modo: .unoParaTodos(responsable: b), actor: a, ahora: ahora)
        return Fixture(casos: casos, repo: r, fake: fake, a: a, b: b, c: c)
    }

    @Test func registraGuardaYMarcaReservado() async throws {
        let f = try await fixtureConReservable()   // reservable cadaUnoElSuyo [a,b] en act1
        let r = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1",
            textoConfirmacion: "vuelo TAP ABC123", actor: f.a, ahora: Date())
        #expect(try r.get().numeroConfirmacion == "ABC123")   // el fake devuelve ABC123
        // el estado de a quedó reservado:
        let reserva = try await f.repo.reserva(activityId: "act1", en: "t1")
        #expect(reserva?.mode == .cadaUnoElSuyo(estados: [f.a: .reservado, f.b: .pendiente]))
    }

    @Test func noMiembroEsNoAutorizado() async throws {
        let f = try await fixtureConReservable()
        let r = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1",
            textoConfirmacion: "x", actor: MiembroId("ext"), ahora: Date())
        #expect(r == .failure(.noAutorizado))
    }

    @Test func ilegibleEsReglaViolada() async throws {
        let f = try await fixtureConReservable()
        let r = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1",
            textoConfirmacion: "__ILEGIBLE__", actor: f.a, ahora: Date())
        #expect(r == .failure(.reglaViolada("confirmacion_ilegible")))
    }

    @Test func redactaTarjetaAntesDeEnviar() async throws {
        let f = try await fixtureConReservable()   // el fake registra ultimoTexto
        _ = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1",
            textoConfirmacion: "pago con tarjeta 4111 1111 1111 1111 vuelo", actor: f.a, ahora: Date())
        #expect(f.fake.ultimoTexto?.contains("4111") == false)
        #expect(f.fake.ultimoTexto?.contains("[REDACTED]") == true)
    }

    @Test func segundaVezNoRellamaLLM() async throws {   // idempotencia por (activityId, miembro)
        let f = try await fixtureConReservable()
        _ = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1", textoConfirmacion: "v1", actor: f.a, ahora: Date())
        let antes = f.fake.llamadas
        _ = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1", textoConfirmacion: "v2", actor: f.a, ahora: Date())
        #expect(f.fake.llamadas == antes)   // no volvió a llamar
    }

    // MARK: - unoParaTodos (fix round 1: cobertura ausente)

    @Test func unoParaTodosPorResponsableOk() async throws {
        let f = try await fixtureUnoParaTodos()   // reservable unoParaTodos(responsable: b) en act1
        let r = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1",
            textoConfirmacion: "reserva hotel Booking XYZ789", actor: f.b, ahora: Date())
        #expect(try r.get().numeroConfirmacion == "XYZ789")
        let reserva = try await f.repo.reserva(activityId: "act1", en: "t1")
        #expect(reserva?.mode == .unoParaTodos(responsable: f.b, estado: .reservado))
    }

    @Test func unoParaTodosPorOwnerOk() async throws {
        let f = try await fixtureUnoParaTodos()   // a = owner, b = responsable
        let r = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1",
            textoConfirmacion: "reserva hotel Booking XYZ789", actor: f.a, ahora: Date())
        #expect(try r.get().numeroConfirmacion == "XYZ789")
    }

    @Test func unoParaTodosPorNoResponsableNoOwnerEsNoAutorizado() async throws {
        let f = try await fixtureUnoParaTodos()   // c ni responsable ni owner
        let r = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1",
            textoConfirmacion: "reserva hotel Booking XYZ789", actor: f.c, ahora: Date())
        #expect(r == .failure(.noAutorizado))
    }

    /// Documenta el comportamiento ACTUAL: la idempotencia está indexada por
    /// actor (`repo.confirmacion(activityId, tripId, actor)`), no por la
    /// reserva compartida de `unoParaTodos`. Para el MISMO actor (`b`), la
    /// segunda llamada no vuelve a invocar el LLM — igual que en
    /// `cadaUnoElSuyo`. El caso borde de que un actor DISTINTO (p.ej. el
    /// owner) pudiera re-disparar el LLM sobre la misma reserva compartida
    /// queda fuera de este test — decisión pendiente de Andrea, no se toca
    /// aquí el keying de producción.
    @Test func segundaVezMismoActorNoRellamaLLM() async throws {
        let f = try await fixtureUnoParaTodos()
        _ = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1", textoConfirmacion: "v1", actor: f.b, ahora: Date())
        let antes = f.fake.llamadas
        _ = try await f.casos.registrarConfirmacion(tripId: "t1", activityId: "act1", textoConfirmacion: "v2", actor: f.b, ahora: Date())
        #expect(f.fake.llamadas == antes)   // no volvió a llamar
    }
}
