// Tests de itinerario (M5, ADR-0020 borrador). El foco es la AUTORIZACIÓN y
// el orden de listado — mismo espíritu que CasosDeUsoVotacionTests.
//
// NOTA sobre el repo en memoria: `Membresia.esMiembro` y `ViajeRepositorio.rol`
// son DOS almacenes separados en `RepositorioEnMemoria` (ver nota de cabecera
// de CasosDeUsoVotacionTests). El test de editar/borrar por owner necesita el
// `rol` real de onboarding, así que monta el viaje con `CasosDeUsoViaje` y
// sincroniza los dos almacenes a mano.

import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Itinerario: actividades (M5, ADR-0020 borrador)")
struct CasosDeUsoItinerarioTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan"), sara = MiembroId("sara")
    let ahora = Date(timeIntervalSince1970: 1_700_000_000)

    func repo() -> RepositorioEnMemoria { RepositorioEnMemoria() }

    // 1a. crear feliz.
    @Test func crearFeliz() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoItinerario(repo: r, membresia: r, viajes: r)

        guard case .success(let a) = try await casos.crear(tripId: "t1", title: "Coliseo", day: "2026-08-02", startTime: "10:00", actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        #expect(a.title == "Coliseo")
        #expect(a.day == "2026-08-02")
        #expect(a.startTime == "10:00")
        #expect(a.createdBy == ana)
    }

    // 1b. title vacío → rechazo.
    @Test func crearConTitleVacioSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoItinerario(repo: r, membresia: r, viajes: r)

        guard case .failure(let error) = try await casos.crear(tripId: "t1", title: "   ", day: "2026-08-02", actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("title_vacio"))
    }

    // 2. listar ordenado por (day, orderIndex).
    @Test func listarOrdenaPorDiaYOrderIndex() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoItinerario(repo: r, membresia: r, viajes: r)

        // Insertadas fuera de orden a propósito.
        guard case .success(let segundoDiaSegundo) = try await casos.crear(tripId: "t1", title: "Museo", day: "2026-08-03", orderIndex: 1, actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        guard case .success(let primerDia) = try await casos.crear(tripId: "t1", title: "Coliseo", day: "2026-08-02", orderIndex: 0, actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        guard case .success(let segundoDiaPrimero) = try await casos.crear(tripId: "t1", title: "Vaticano", day: "2026-08-03", orderIndex: 0, actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }

        guard case .success(let items) = try await casos.listar(tripId: "t1", actor: ana) else {
            Issue.record("esperaba listar exitoso"); return
        }
        #expect(items.map(\.id) == [primerDia.id, segundoDiaPrimero.id, segundoDiaSegundo.id])
    }

    // 3. no-miembro no ve ni crea: mismo error exista o no la actividad (sin fuga de existencia).
    @Test func noMiembroNoVeNiCreaSinFugaDeExistencia() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoItinerario(repo: r, membresia: r, viajes: r)

        guard case .success = try await casos.crear(tripId: "t1", title: "Coliseo", day: "2026-08-02", actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }

        guard case .failure(let errorListar) = try await casos.listar(tripId: "t1", actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorListar == .noAutorizado)

        guard case .failure(let errorCrear) = try await casos.crear(tripId: "t1", title: "Museo", day: "2026-08-03", actor: sara, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorCrear == .noAutorizado)
    }

    // 4. solo creador o owner editan y borran; otro member → noAutorizado.
    @Test func soloCreadorOOwnerEditanYBorran() async throws {
        let r = repo()
        let casosViaje = CasosDeUsoViaje(repo: r)
        let viaje = try await casosViaje.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora)
        guard case .success(let invitacion) = try await casosViaje.invitar(tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba invitar exitoso"); return
        }
        #expect(try await casosViaje.unirse(code: invitacion.code, actor: ivan, ahora: ahora) == .unido)
        #expect(try await casosViaje.unirse(code: invitacion.code, actor: sara, ahora: ahora) == .unido)
        // Sincroniza el almacén de Membresia con el de onboarding (ver nota de cabecera).
        for m in [ana, ivan, sara] { await r.anadirMiembro(m, a: viaje.id) }

        let casos = CasosDeUsoItinerario(repo: r, membresia: r, viajes: r)

        // ivan (member, NO owner) crea la actividad → él es el creador.
        guard case .success(let actividad) = try await casos.crear(tripId: viaje.id, title: "Coliseo", day: "2026-08-02", actor: ivan, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }

        // sara (ni creadora ni owner) intenta editar/borrar la actividad de ivan → noAutorizado.
        guard case .failure(let errorEditar) = try await casos.editar(itemId: actividad.id, tripId: viaje.id, title: "Coliseo (cambiado)", day: "2026-08-02", startTime: nil, location: nil, notes: nil, orderIndex: 0, actor: sara, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorEditar == .noAutorizado)

        guard case .failure(let errorBorrar) = try await casos.borrar(itemId: actividad.id, tripId: viaje.id, actor: sara, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorBorrar == .noAutorizado)

        // ivan (creador, no owner) SÍ puede editar su propia actividad.
        guard case .success(let editada) = try await casos.editar(itemId: actividad.id, tripId: viaje.id, title: "Coliseo (cambiado)", day: "2026-08-02", startTime: "11:00", location: nil, notes: nil, orderIndex: 0, actor: ivan, ahora: ahora) else {
            Issue.record("esperaba editar exitoso (creador)"); return
        }
        #expect(editada.title == "Coliseo (cambiado)")
        #expect(editada.startTime == "11:00")

        // ana (owner, no creadora) también puede editar y borrar.
        guard case .success = try await casos.editar(itemId: actividad.id, tripId: viaje.id, title: "Coliseo (owner)", day: "2026-08-02", startTime: "12:00", location: nil, notes: nil, orderIndex: 0, actor: ana, ahora: ahora) else {
            Issue.record("esperaba editar exitoso (owner)"); return
        }
        guard case .success = try await casos.borrar(itemId: actividad.id, tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba borrar exitoso (owner)"); return
        }
    }

    // 5. crear/editar en viaje cerrado → rechazo.
    @Test func crearYEditarEnViajeCerradoSeRechazan() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoItinerario(repo: r, membresia: r, viajes: r)

        guard case .success(let actividad) = try await casos.crear(tripId: "t1", title: "Coliseo", day: "2026-08-02", actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        await r.cerrarViaje("t1")

        guard case .failure(let errorCrear) = try await casos.crear(tripId: "t1", title: "Museo", day: "2026-08-03", actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorCrear == .viajeCerrado)

        guard case .failure(let errorEditar) = try await casos.editar(itemId: actividad.id, tripId: "t1", title: "Coliseo (cambiado)", day: "2026-08-02", startTime: nil, location: nil, notes: nil, orderIndex: 0, actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorEditar == .viajeCerrado)
    }

    // Codex M5 P1: un ex-miembro que creó la actividad NO puede editarla/borrarla tras salir.
    @Test func exMiembroNoEditaNiBorra() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoItinerario(repo: r, membresia: r, viajes: r)
        guard case .success(let actividad) = try await casos.crear(tripId: "t1", title: "Coliseo", day: "2026-08-02", actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear"); return
        }
        await r.quitarDeMembresia(ana, de: "t1")   // ana sale del viaje (createdBy sigue siendo ana)
        guard case .failure(let eEditar) = try await casos.editar(itemId: actividad.id, tripId: "t1", title: "Foro", day: "2026-08-02", actor: ana, ahora: ahora) else {
            Issue.record("editar deberia fallar para ex-miembro"); return
        }
        #expect(eEditar == .noAutorizado)
        guard case .failure(let eBorrar) = try await casos.borrar(itemId: actividad.id, tripId: "t1", actor: ana, ahora: ahora) else {
            Issue.record("borrar deberia fallar para ex-miembro"); return
        }
        #expect(eBorrar == .noAutorizado)
    }

    // MARK: - Tope de listado (patrón chat: clamp [1,200] en el caso de uso)

    /// Siembra 3 actividades EN EL MISMO día y con el MISMO `orderIndex`: así el único
    /// desempate posible es el `id`, que es justo lo que se acaba de añadir al orden.
    private func conActividadesEmpatadas() async throws -> (RepositorioEnMemoria, CasosDeUsoItinerario) {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoItinerario(repo: r, membresia: r, viajes: r)
        for titulo in ["Coliseo", "Foro", "Vaticano"] {
            guard case .success = try await casos.crear(
                tripId: "t1", title: titulo, day: "2026-08-01", orderIndex: 0, actor: ana, ahora: ahora) else {
                Issue.record("esperaba crear exitoso"); break
            }
        }
        return (r, casos)
    }

    /// Un `limit` fuera de rango NUNCA se rechaza: se ajusta en silencio. 0 sube a 1,
    /// 999 baja a 200 (y con 3 actividades, 200 las devuelve todas).
    @Test func listarClampaElLimiteEnVezDeRechazarlo() async throws {
        let (_, casos) = try await conActividadesEmpatadas()

        guard case .success(let cero) = try await casos.listar(tripId: "t1", actor: ana, limit: 0),
              case .success(let negativo) = try await casos.listar(tripId: "t1", actor: ana, limit: -5),
              case .success(let enorme) = try await casos.listar(tripId: "t1", actor: ana, limit: 999),
              case .success(let porDefecto) = try await casos.listar(tripId: "t1", actor: ana) else {
            Issue.record("esperaba listar exitoso"); return
        }
        #expect(cero.count == 1)         // 0 -> 1
        #expect(negativo.count == 1)     // negativo -> 1
        #expect(enorme.count == 3)       // 999 -> 200 (caben las 3)
        #expect(porDefecto.count == 3)   // default 50
    }

    /// `(day, orderIndex)` NO desempata: con tres actividades del mismo día e igual
    /// índice, sin el `id` final el orden sería arbitrario y `limit` devolvería una
    /// página distinta cada vez.
    @Test func listarDesempataPorIdYLaPaginaEsPrefijo() async throws {
        let (_, casos) = try await conActividadesEmpatadas()

        guard case .success(let completa) = try await casos.listar(tripId: "t1", actor: ana, limit: 200),
              case .success(let repetida) = try await casos.listar(tripId: "t1", actor: ana, limit: 200),
              case .success(let pagina) = try await casos.listar(tripId: "t1", actor: ana, limit: 2) else {
            Issue.record("esperaba listar exitoso"); return
        }
        #expect(completa.map(\.id) == completa.map(\.id).sorted())   // el id es el desempate
        #expect(repetida.map(\.id) == completa.map(\.id))            // repetible
        #expect(pagina.map(\.id) == Array(completa.map(\.id).prefix(2)))
    }

    /// `detalle` (la carga que usa el PATCH de la ruta) NO depende del tope: encuentra
    /// una actividad que se cae fuera de la primera página, y mantiene el mismo
    /// `.noAutorizado` sin fuga para el no-miembro.
    @Test func detalleEncuentraFueraDeLaPrimeraPaginaYNoFiltraExistencia() async throws {
        let (_, casos) = try await conActividadesEmpatadas()
        guard case .success(let completa) = try await casos.listar(tripId: "t1", actor: ana, limit: 200) else {
            Issue.record("esperaba listar exitoso"); return
        }
        let ultima = completa[2].id   // fuera de una página de tamaño 1

        guard case .success(let item) = try await casos.detalle(itemId: ultima, tripId: "t1", actor: ana) else {
            Issue.record("detalle debe encontrarla aunque no esté en la primera página"); return
        }
        #expect(item.id == ultima)

        guard case .failure(let errorSara) = try await casos.detalle(itemId: ultima, tripId: "t1", actor: sara) else {
            Issue.record("un no-miembro no ve el detalle"); return
        }
        #expect(errorSara == .noAutorizado)

        guard case .failure(let errorInexistente) = try await casos.detalle(itemId: "no-existe", tripId: "t1", actor: ana) else {
            Issue.record("una actividad inexistente es noAutorizado, sin fuga"); return
        }
        #expect(errorInexistente == .noAutorizado)
    }
}
