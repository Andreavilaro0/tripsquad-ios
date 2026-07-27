// Tests de chat (M6, ADR-0021 borrador). El foco es la AUTORIZACIÓN y la
// paginación cronológica — mismo espíritu que CasosDeUsoItinerarioTests.

import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Chat: mensajes (M6, ADR-0021 borrador)")
struct CasosDeUsoChatTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan"), sara = MiembroId("sara")
    let ahora = Date(timeIntervalSince1970: 1_700_000_000)

    func repo() -> RepositorioEnMemoria { RepositorioEnMemoria() }

    // 1. enviar feliz.
    @Test func enviarFeliz() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        guard case .success(let m) = try await casos.enviar(tripId: "t1", body: "Hola squad", actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar exitoso"); return
        }
        #expect(m.body == "Hola squad")
        #expect(m.autor == ana)
        #expect(m.tripId == "t1")
        #expect(m.deletedAt == nil)
    }

    // 2a. body vacío (o solo espacios) se rechaza.
    @Test func bodyVacioSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        guard case .failure(let error) = try await casos.enviar(tripId: "t1", body: "   ", actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("body_vacio"))
    }

    // 2b. body >4000 caracteres se rechaza.
    @Test func bodyDemasiadoLargoSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        let bodyLargo = String(repeating: "a", count: 4001)
        guard case .failure(let error) = try await casos.enviar(tripId: "t1", body: bodyLargo, actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("body_muy_largo"))
    }

    // 2c. body de exactamente 4000 caracteres SÍ se acepta (límite inclusive).
    @Test func bodyDe4000CaracteresSeAcepta() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        let bodyLimite = String(repeating: "a", count: 4000)
        guard case .success(let m) = try await casos.enviar(tripId: "t1", body: bodyLimite, actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar exitoso"); return
        }
        #expect(m.body.count == 4000)
    }

    // 2d. El límite se mide en code points (Unicode scalars), no en grapheme clusters —
    // misma unidad que el CHECK char_length de Postgres (bot GitHub M6 P2). 2001 emojis
    // bandera = 2001 grapheme clusters PERO 4002 scalars: el dominio DEBE rechazarlo con
    // 422 antes de llegar a la BD, aunque `body.count` (2001) esté muy por debajo de 4000.
    @Test func bodyQueExcedeEnScalarsPeroNoEnGraphemesSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        let bandera = "\u{1F1EA}\u{1F1F8}"          // 🇪🇸 = 1 grapheme, 2 scalars
        let body = String(repeating: bandera, count: 2001)  // 2001 graphemes, 4002 scalars
        #expect(body.count == 2001)
        #expect(body.unicodeScalars.count == 4002)
        guard case .failure(let error) = try await casos.enviar(tripId: "t1", body: body, actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure: excede 4000 scalars aunque no en graphemes"); return
        }
        #expect(error == .reglaViolada("body_muy_largo"))
    }

    // 3. no-miembro no envía ni lista: mismo error, sin fuga de existencia.
    @Test func noMiembroNoEnviaNiListaSinFugaDeExistencia() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        guard case .success = try await casos.enviar(tripId: "t1", body: "Hola", actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar exitoso"); return
        }

        guard case .failure(let errorListar) = try await casos.listar(tripId: "t1", actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorListar == .noAutorizado)

        guard case .failure(let errorEnviar) = try await casos.enviar(tripId: "t1", body: "Hola", actor: sara, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorEnviar == .noAutorizado)
    }

    // 4. listar con since/limit devuelve cronológico y respeta el límite.
    @Test func listarConSinceYLimitDevuelveCronologicoYRespetaLimit() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        guard case .success(let m1) = try await casos.enviar(tripId: "t1", body: "uno", actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar"); return
        }
        guard case .success(let m2) = try await casos.enviar(tripId: "t1", body: "dos", actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar"); return
        }
        guard case .success(let m3) = try await casos.enviar(tripId: "t1", body: "tres", actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar"); return
        }

        // Sin since ni limit explícito: los tres, en orden cronológico.
        guard case .success(let todos) = try await casos.listar(tripId: "t1", actor: ana) else {
            Issue.record("esperaba listar"); return
        }
        #expect(todos.map(\.id) == [m1.id, m2.id, m3.id])

        // since = m1.id: solo m2 y m3 (id > since).
        guard case .success(let desdeM1) = try await casos.listar(tripId: "t1", actor: ana, since: m1.id) else {
            Issue.record("esperaba listar"); return
        }
        #expect(desdeM1.map(\.id) == [m2.id, m3.id])

        // limit = 2: solo los dos primeros cronológicamente.
        guard case .success(let limitados) = try await casos.listar(tripId: "t1", actor: ana, limit: 2) else {
            Issue.record("esperaba listar"); return
        }
        #expect(limitados.map(\.id) == [m1.id, m2.id])
    }

    // 5. borrar: solo el autor; otro miembro → noAutorizado.
    @Test func soloElAutorBorra() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        await r.anadirMiembro(ivan, a: "t1")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        guard case .success(let m) = try await casos.enviar(tripId: "t1", body: "Hola", actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar"); return
        }

        // ivan (miembro, NO autor) intenta borrar el mensaje de ana → noAutorizado.
        guard case .failure(let error) = try await casos.borrar(msgId: m.id, tripId: "t1", actor: ivan, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)

        // ana (autora) sí puede borrar su propio mensaje.
        guard case .success = try await casos.borrar(msgId: m.id, tripId: "t1", actor: ana, ahora: ahora) else {
            Issue.record("esperaba borrar exitoso"); return
        }
    }

    // 6. mensaje borrado aparece en el listado con marcador y deletedAt puesto
    // (no desaparece del hilo).
    @Test func mensajeBorradoApareceConMarcadorYDeletedAt() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        guard case .success(let m) = try await casos.enviar(tripId: "t1", body: "Secreto", actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar"); return
        }
        guard case .success = try await casos.borrar(msgId: m.id, tripId: "t1", actor: ana, ahora: ahora) else {
            Issue.record("esperaba borrar exitoso"); return
        }

        guard case .success(let mensajes) = try await casos.listar(tripId: "t1", actor: ana) else {
            Issue.record("esperaba listar"); return
        }
        #expect(mensajes.count == 1)
        #expect(mensajes[0].deletedAt == ahora)
        #expect(mensajes[0].body == Mensaje.marcadorBorrado)
    }

    // 7. no-miembro no borra (mismo error sin fuga, aunque el mensaje exista).
    @Test func noMiembroNoBorra() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        guard case .success(let m) = try await casos.enviar(tripId: "t1", body: "Hola", actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar"); return
        }
        guard case .failure(let error) = try await casos.borrar(msgId: m.id, tripId: "t1", actor: sara, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)
    }

    // 8. Bead iou (Codex ronda 2): un MIEMBRO que borra un `msgId` que nunca existió EN SU
    // viaje, o que existe pero en OTRO viaje, obtiene éxito idempotente — NO `.noAutorizado`.
    // Un 403 exclusivo para "no existe" sería un oráculo, y además rompería el reintento de
    // un borrado ya aplicado (ADR-0013 §2, mismo criterio que `RepositorioEnMemoria.eliminar`
    // de gastos). `.noAutorizado` solo aparece si el mensaje SÍ existe en el viaje pero el
    // actor no es su autor (ver `soloElAutorBorra`/`noMiembroNoBorra`).
    @Test func borrarMensajeInexistenteOdeOtroViajeEsIdempotente() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        await r.anadirMiembro(ana, a: "t2")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        // Nunca existió en t1.
        guard case .success = try await casos.borrar(msgId: 999, tripId: "t1", actor: ana, ahora: ahora) else {
            Issue.record("esperaba borrar exitoso (idempotente) para mensaje inexistente"); return
        }

        // Existe, pero en OTRO viaje (t2) — borrarlo "desde" t1 no debe filtrar que existe
        // en t2: mismo resultado, y sigue intacto (sin `deletedAt`) en t2.
        guard case .success(let enT2) = try await casos.enviar(tripId: "t2", body: "Hola", actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar en t2"); return
        }
        guard case .success = try await casos.borrar(msgId: enT2.id, tripId: "t1", actor: ana, ahora: ahora) else {
            Issue.record("esperaba borrar exitoso (idempotente) para mensaje de otro viaje"); return
        }
        guard case .success(let mensajesT2) = try await casos.listar(tripId: "t2", actor: ana) else {
            Issue.record("esperaba listar en t2"); return
        }
        #expect(mensajesT2.first?.deletedAt == nil)
    }

    // 9. el id del mensaje es monotónico GLOBAL, no reinicia por viaje.
    @Test func idEsMonotonicoGlobalEntreViajes() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        await r.anadirMiembro(ivan, a: "t2")
        let casos = CasosDeUsoChat(repo: r, membresia: r)

        guard case .success(let m1) = try await casos.enviar(tripId: "t1", body: "uno", actor: ana, ahora: ahora) else {
            Issue.record("esperaba enviar"); return
        }
        guard case .success(let m2) = try await casos.enviar(tripId: "t2", body: "dos", actor: ivan, ahora: ahora) else {
            Issue.record("esperaba enviar"); return
        }
        #expect(m2.id > m1.id)
    }
}
