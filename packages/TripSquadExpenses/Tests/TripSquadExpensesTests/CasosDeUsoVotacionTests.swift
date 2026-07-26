// Tests de votaciones (M4, ADR-0019 borrador). El foco es la AUTORIZACIÓN y la
// semántica de upsert del voto — mismo espíritu que CasosDeUsoViajeTests.
//
// NOTA sobre el repo en memoria: `Membresia.esMiembro` y `ViajeRepositorio.rol` ya
// derivan del MISMO almacén (`miembrosDeViaje`), igual que en Postgres ambos leen
// `trip_members`. Antes eran dos almacenes desconectados y el doble mentía: unirse o
// ser expulsado no afectaba a `esMiembro`, así que ningún test podía detectar
// regresiones de "miembro ACTUAL" — que es exactamente cómo se coló el agujero de
// `cerrar` que cubre `exMiembroNoCierraSuPropiaVotacion`. `anadirMiembro` sigue
// existiendo como atajo para sembrar sin pasar por invitación.

import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Votaciones: polls + votos (M4, ADR-0019 borrador)")
struct CasosDeUsoVotacionTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan"), sara = MiembroId("sara")
    let ahora = Date(timeIntervalSince1970: 1_700_000_000)

    func repo() -> RepositorioEnMemoria { RepositorioEnMemoria() }

    // 1a. crear con ≥2 opciones → éxito.
    @Test func crearConDosOMasOpciones() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)

        guard case .success(let v) = try await casos.crear(tripId: "t1", question: "¿Playa o montaña?", options: ["playa", "montaña"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        #expect(v.options == ["playa", "montaña"])
        #expect(v.createdBy == ana)
        #expect(v.closedAt == nil)
    }

    // 1b. crear con <2 opciones → rechazo.
    @Test func crearConMenosDeDosOpcionesSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)

        guard case .failure(let error) = try await casos.crear(tripId: "t1", question: "¿Playa?", options: ["playa"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("min_2_options"))
    }

    @Test func crearConOpcionesDuplicadasSeRechaza() async throws {   // bot Codex P1
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)
        guard case .failure(let error) = try await casos.crear(tripId: "t1", question: "¿?", options: ["a", "a"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("duplicate_options"))
    }

    // MARK: - Topes de longitud/cardinalidad (bead mjp: campos de texto libre sin límite)

    @Test func crearConQuestionMuyLargaSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)
        let questionLarga = String(repeating: "a", count: 501)
        guard case .failure(let error) = try await casos.crear(tripId: "t1", question: questionLarga, options: ["a", "b"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("question_muy_larga"))
    }

    @Test func crearConOptionMuyLargaSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)
        let optionLarga = String(repeating: "a", count: 201)
        guard case .failure(let error) = try await casos.crear(tripId: "t1", question: "¿?", options: [optionLarga, "b"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("option_muy_larga"))
    }

    @Test func crearConMasDeMaxOpcionesSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)
        let muchasOpciones = (1...21).map { "opcion\($0)" }
        guard case .failure(let error) = try await casos.crear(tripId: "t1", question: "¿?", options: muchasOpciones, actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("max_opciones_superado"))
    }

    @Test func crearConExactamente20OpcionesSeAcepta() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)
        let veinteOpciones = (1...20).map { "opcion\($0)" }
        guard case .success(let v) = try await casos.crear(tripId: "t1", question: "¿?", options: veinteOpciones, actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        #expect(v.options.count == 20)
    }

    // 2. votar feliz: se registra y aparece en el conteo del detalle.
    @Test func votarFeliz() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        await r.anadirMiembro(ivan, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)

        guard case .success(let v) = try await casos.crear(tripId: "t1", question: "q", options: ["a", "b"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        guard case .success(let resultado) = try await casos.votar(pollId: v.id, tripId: "t1", choice: "a", actor: ivan, ahora: ahora) else {
            Issue.record("esperaba votar exitoso"); return
        }
        #expect(resultado == .registrado)

        guard case .success(let detalle) = try await casos.detalle(pollId: v.id, tripId: "t1", actor: ana) else {
            Issue.record("esperaba detalle exitoso"); return
        }
        #expect(detalle.conteo["a"] == 1)
        #expect(detalle.conteo["b"] == 0, "opciones sin voto deben aparecer en el conteo con 0")
        #expect(detalle.votos.count == 1)
        #expect(detalle.votos.first?.0 == ivan)
        #expect(detalle.votos.first?.1 == "a")
    }

    // 3. cambiar voto: UPSERT sobre (pollId, member) — no duplica, se sobrescribe.
    @Test func cambiarVotoEsUpsertNoDuplica() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        await r.anadirMiembro(ivan, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)

        guard case .success(let v) = try await casos.crear(tripId: "t1", question: "q", options: ["a", "b"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        _ = try await casos.votar(pollId: v.id, tripId: "t1", choice: "a", actor: ivan, ahora: ahora)
        _ = try await casos.votar(pollId: v.id, tripId: "t1", choice: "b", actor: ivan, ahora: ahora)

        guard case .success(let detalle) = try await casos.detalle(pollId: v.id, tripId: "t1", actor: ana) else {
            Issue.record("esperaba detalle exitoso"); return
        }
        #expect(detalle.conteo["a"] == 0)
        #expect(detalle.conteo["b"] == 1)
        #expect(detalle.votos.count == 1, "no debe duplicar la fila de ivan al cambiar de opción")
    }

    // 4. option inválida → rechazo (no es un error de autorización: el actor SÍ vota).
    @Test func votarOptionInvalidaSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)

        guard case .success(let v) = try await casos.crear(tripId: "t1", question: "q", options: ["a", "b"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        guard case .success(let resultado) = try await casos.votar(pollId: v.id, tripId: "t1", choice: "c", actor: ana, ahora: ahora) else {
            Issue.record("esperaba un resultado de negocio, no un error de autorización"); return
        }
        #expect(resultado == .rechazado(razon: "invalid_option"))
    }

    // 5. votar en votación ya cerrada → rechazo.
    @Test func votarEnVotacionCerradaSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)

        guard case .success(let v) = try await casos.crear(tripId: "t1", question: "q", options: ["a", "b"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        await r.cerrar(pollId: v.id, en: "t1", ahora: ahora)

        guard case .success(let resultado) = try await casos.votar(pollId: v.id, tripId: "t1", choice: "a", actor: ana, ahora: ahora) else {
            Issue.record("esperaba un resultado de negocio, no un error de autorización"); return
        }
        #expect(resultado == .rechazado(razon: "poll_closed"))
    }

    // 6. no-miembro no ve ni vota: mismo error exista o no la poll (sin fuga de existencia).
    @Test func noMiembroNoVeNiVotaNiCreaSinFugaDeExistencia() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)

        guard case .success(let v) = try await casos.crear(tripId: "t1", question: "q", options: ["a", "b"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }

        guard case .failure(let errorDetalleReal) = try await casos.detalle(pollId: v.id, tripId: "t1", actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        guard case .failure(let errorDetalleInexistente) = try await casos.detalle(pollId: "no-existe", tripId: "t1", actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorDetalleReal == .noAutorizado)
        #expect(errorDetalleReal == errorDetalleInexistente, "mismo error exista o no la poll: sin fuga de existencia")

        guard case .failure(let errorVotar) = try await casos.votar(pollId: v.id, tripId: "t1", choice: "a", actor: sara, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorVotar == .noAutorizado)

        guard case .failure(let errorCrear) = try await casos.crear(tripId: "t1", question: "q2", options: ["x", "y"], actor: sara, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorCrear == .noAutorizado)

        guard case .failure(let errorListar) = try await casos.listar(tripId: "t1", actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorListar == .noAutorizado)
    }

    // 7. solo el creador de la poll o el owner del viaje cierran; otro member → noAutorizado.
    @Test func soloCreadorOOwnerCierran() async throws {
        let r = repo()
        let casosViaje = CasosDeUsoViaje(repo: r)
        let viaje = try await casosViaje.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora).get()
        guard case .success(let invitacion) = try await casosViaje.invitar(tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba invitar exitoso"); return
        }
        #expect(try await casosViaje.unirse(code: invitacion.code, actor: ivan, ahora: ahora) == .unido)
        #expect(try await casosViaje.unirse(code: invitacion.code, actor: sara, ahora: ahora) == .unido)
        // Sincroniza el almacén de Membresia con el de onboarding (ver nota de cabecera).
        for m in [ana, ivan, sara] { await r.anadirMiembro(m, a: viaje.id) }

        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)

        // ivan (member, NO owner) crea la primera poll → él es el creador.
        guard case .success(let v1) = try await casos.crear(tripId: viaje.id, question: "q1", options: ["a", "b"], actor: ivan, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }

        // sara (ni creadora ni owner) intenta cerrar la poll de ivan → noAutorizado.
        guard case .failure(let error) = try await casos.cerrar(pollId: v1.id, tripId: viaje.id, actor: sara, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)

        // ivan (creador, no owner) SÍ puede cerrar su propia poll.
        guard case .success = try await casos.cerrar(pollId: v1.id, tripId: viaje.id, actor: ivan, ahora: ahora) else {
            Issue.record("esperaba cerrar exitoso (creador)"); return
        }

        // segunda poll, también creada por ivan: el OWNER (ana, no creadora) también puede cerrarla.
        guard case .success(let v2) = try await casos.crear(tripId: viaje.id, question: "q2", options: ["x", "y"], actor: ivan, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        guard case .success = try await casos.cerrar(pollId: v2.id, tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba cerrar exitoso (owner)"); return
        }
    }

    // 8. crear/votar en viaje cerrado → rechazo (coherencia con onboarding/settle).
    @Test func crearYVotarEnViajeCerradoSeRechazan() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)

        guard case .success(let v) = try await casos.crear(tripId: "t1", question: "q", options: ["a", "b"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        await r.cerrarViaje("t1")

        guard case .failure(let errorCrear) = try await casos.crear(tripId: "t1", question: "q2", options: ["x", "y"], actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorCrear == .viajeCerrado)

        guard case .failure(let errorVotar) = try await casos.votar(pollId: v.id, tripId: "t1", choice: "a", actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorVotar == .viajeCerrado)
    }

    // P1 de la revisión integrada: `cerrar` autorizaba por `createdBy == actor` SIN
    // comprobar membresía actual, así que un EXPULSADO seguía cerrando las votaciones
    // que creó. Es el mismo agujero que ya se tapó en itinerario (M5) y fotos (M7).
    //
    // El test recorre el flujo REAL (crear viaje -> invitar -> unirse -> expulsar con
    // `quitarMiembro`), no los atajos de siembra: así prueba de verdad la autorización
    // de extremo a extremo, que es lo que antes era imposible.
    @Test func exMiembroNoCierraSuPropiaVotacion() async throws {
        let r = repo()
        let casosViaje = CasosDeUsoViaje(repo: r)
        let viaje = try await casosViaje.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora).get()
        guard case .success(let invitacion) = try await casosViaje.invitar(tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba invitar exitoso"); return
        }
        #expect(try await casosViaje.unirse(code: invitacion.code, actor: ivan, ahora: ahora) == .unido)

        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)
        guard case .success(let votacion) = try await casos.crear(
            tripId: viaje.id, question: "¿Playa o montaña?", options: ["playa", "montaña"],
            actor: ivan, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }

        // ivan es expulsado por el camino real; su `createdBy` sigue apuntándole.
        await r.quitarMiembro(ivan, de: viaje.id, ahora: ahora)

        guard case .failure(let error) = try await casos.cerrar(
            pollId: votacion.id, tripId: viaje.id, actor: ivan, ahora: ahora) else {
            Issue.record("un ex-miembro NO debe poder cerrar su propia votación"); return
        }
        #expect(error == .noAutorizado)

        // Y la votación sigue abierta (el cierre no llegó a ejecutarse).
        guard case .success(let resultado) = try await casos.detalle(
            pollId: votacion.id, tripId: viaje.id, actor: ana) else {
            Issue.record("ana (owner y miembro) sí ve el detalle"); return
        }
        #expect(resultado.votacion.closedAt == nil)
    }

    // MARK: - Tope de listado (patrón chat: clamp [1,200] en el caso de uso)

    /// Siembra `n` votaciones en `t1` con ana de miembro.
    private func conVotaciones(_ n: Int) async throws -> (RepositorioEnMemoria, CasosDeUsoVotacion) {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoVotacion(repo: r, membresia: r, viajes: r)
        for i in 0..<n {
            guard case .success = try await casos.crear(
                tripId: "t1", question: "pregunta \(i)", options: ["a", "b"], actor: ana, ahora: ahora) else {
                Issue.record("esperaba crear exitoso"); break
            }
        }
        return (r, casos)
    }

    /// Un `limit` fuera de rango NUNCA se rechaza: se ajusta en silencio. 0 sube a 1,
    /// 999 baja a 200 (y con 3 votaciones, 200 las devuelve todas).
    @Test func listarClampaElLimiteEnVezDeRechazarlo() async throws {
        let (_, casos) = try await conVotaciones(3)

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

    /// El orden debe ser TOTAL y repetible (por `id`, igual que `ORDER BY id` en
    /// Postgres): sin él, la página nº2 podría repetir u omitir votaciones.
    @Test func listarTieneOrdenEstableYLaPaginaEsPrefijo() async throws {
        let (_, casos) = try await conVotaciones(3)

        guard case .success(let completa) = try await casos.listar(tripId: "t1", actor: ana, limit: 200),
              case .success(let repetida) = try await casos.listar(tripId: "t1", actor: ana, limit: 200),
              case .success(let pagina) = try await casos.listar(tripId: "t1", actor: ana, limit: 2) else {
            Issue.record("esperaba listar exitoso"); return
        }
        #expect(completa.map(\.id) == completa.map(\.id).sorted())
        #expect(repetida.map(\.id) == completa.map(\.id))
        #expect(pagina.map(\.id) == Array(completa.map(\.id).prefix(2)))
    }
}
