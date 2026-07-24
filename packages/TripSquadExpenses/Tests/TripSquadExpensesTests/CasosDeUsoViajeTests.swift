// Tests de onboarding (ADR-0018). El foco es la AUTORIZACIÓN: quién puede ver,
// invitar, expulsar, cerrar — y que nada de eso filtre existencia a quien no
// tiene derecho a saberlo.

import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Onboarding: viajes + miembros + invitaciones (ADR-0018)")
struct CasosDeUsoViajeTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan"), sara = MiembroId("sara")
    let ahora = Date(timeIntervalSince1970: 1_700_000_000)

    func entorno() -> (CasosDeUsoViaje, RepositorioEnMemoria) {
        let repo = RepositorioEnMemoria()
        return (CasosDeUsoViaje(repo: repo), repo)
    }

    /// Crea un viaje con `ana` de owner e invita, devolviendo el code. Atajo
    /// para no repetir el mismo boilerplate en cada test.
    func viajeConInvitacion(_ casos: CasosDeUsoViaje) async throws -> (tripId: String, code: String) {
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora)
        guard case .success(let invitacion) = try await casos.invitar(tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba invitar exitoso"); return (viaje.id, "")
        }
        return (viaje.id, invitacion.code)
    }

    // 1. crear → el creador es owner y miembro; aparece en misViajes.
    @Test func crearHaceAlCreadorOwnerYMiembro() async throws {
        let (casos, _) = entorno()
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora)
        #expect(viaje.createdBy == ana)

        let misViajes = try await casos.misViajes(actor: ana)
        #expect(misViajes.map(\.id) == [viaje.id])

        guard case .success(let (v, miembros)) = try await casos.detalle(tripId: viaje.id, actor: ana) else {
            Issue.record("esperaba detalle exitoso"); return
        }
        #expect(v.id == viaje.id)
        #expect(miembros.count == 1)
        #expect(miembros.first?.0 == ana)
        #expect(miembros.first?.1 == .owner)
    }

    // 2. unirse feliz: crear (owner A), invitar, unirse (B) → B es member.
    @Test func unirseFeliz() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)

        let resultado = try await casos.unirse(code: code, actor: ivan, ahora: ahora)
        #expect(resultado == .unido)

        guard case .success(let (_, miembros)) = try await casos.detalle(tripId: tripId, actor: ana) else {
            Issue.record("esperaba detalle exitoso"); return
        }
        let porId = Dictionary(uniqueKeysWithValues: miembros)
        #expect(porId[ana] == .owner)
        #expect(porId[ivan] == .member)
        #expect(miembros.count == 2)
    }

    // 3. código caducado (ahora > expiresAt) → .caducado, B no entra.
    @Test func codigoCaducadoNoDejaUnirse() async throws {
        let (casos, _) = entorno()
        let (_, code) = try await viajeConInvitacion(casos)
        let ochoDiasDespues = ahora.addingTimeInterval(8 * 24 * 60 * 60)

        let resultado = try await casos.unirse(code: code, actor: ivan, ahora: ochoDiasDespues)
        #expect(resultado == .caducado)
    }

    // 4. código revocado → .revocado.
    @Test func codigoRevocadoNoDejaUnirse() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)

        guard case .success = try await casos.revocar(code: code, tripId: tripId, actor: ana, ahora: ahora) else {
            Issue.record("esperaba revocar exitoso"); return
        }
        let resultado = try await casos.unirse(code: code, actor: ivan, ahora: ahora)
        #expect(resultado == .revocado)
    }

    // 5. unirse a viaje cerrado → .viajeCerrado.
    @Test func unirseAViajeCerrado() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)

        guard case .success = try await casos.cerrar(tripId: tripId, actor: ana, ahora: ahora) else {
            Issue.record("esperaba cerrar exitoso"); return
        }
        let resultado = try await casos.unirse(code: code, actor: ivan, ahora: ahora)
        #expect(resultado == .viajeCerrado)
    }

    // 6. yaMiembro: unirse dos veces con el mismo code → segunda vez .yaMiembro (no duplica).
    @Test func unirseDosVecesEsYaMiembroSinDuplicar() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)

        let primero = try await casos.unirse(code: code, actor: ivan, ahora: ahora)
        #expect(primero == .unido)
        let segundo = try await casos.unirse(code: code, actor: ivan, ahora: ahora)
        #expect(segundo == .yaMiembro)

        guard case .success(let (_, miembros)) = try await casos.detalle(tripId: tripId, actor: ana) else {
            Issue.record("esperaba detalle exitoso"); return
        }
        #expect(miembros.count == 2, "no debe duplicar la fila de ivan")
    }

    // 7. tope lleno: test del repo directamente con tope bajo (2), como sugiere el brief.
    @Test func topeDeMiembrosLleno() async throws {
        let repo = RepositorioEnMemoria()
        _ = try await repo.crearViaje(id: "t1", name: "Roma", baseCurrency: "EUR", creador: ana, ahora: ahora)
        _ = try await repo.crearInvitacion(tripId: "t1", por: ana, code: "c1", expiresAt: ahora.addingTimeInterval(3600))

        // ana (owner) ya cuenta como 1/2. ivan la completa a 2/2.
        let r1 = try await repo.unirsePorCodigo(code: "c1", actor: ivan, ahora: ahora, tope: 2)
        #expect(r1 == .unido)
        let r2 = try await repo.unirsePorCodigo(code: "c1", actor: sara, ahora: ahora, tope: 2)
        #expect(r2 == .lleno)
    }

    // 8. no-miembro NO ve el detalle → .noAutorizado, y da lo MISMO exista o no el viaje.
    @Test func noMiembroNoVeDetalleSinFugaDeExistencia() async throws {
        let (casos, _) = entorno()
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora)

        guard case .failure(let errorViajeReal) = try await casos.detalle(tripId: viaje.id, actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        guard case .failure(let errorViajeInexistente) = try await casos.detalle(tripId: "no-existe", actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorViajeReal == .noAutorizado)
        #expect(errorViajeInexistente == .noAutorizado)
        #expect(errorViajeReal == errorViajeInexistente, "mismo error exista o no el viaje: sin fuga de existencia")
    }

    // 9. solo owner expulsa: un member intenta expulsar → .noAutorizado.
    @Test func soloOwnerExpulsa() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)
        #expect(try await casos.unirse(code: code, actor: ivan, ahora: ahora) == .unido)
        #expect(try await casos.unirse(code: code, actor: sara, ahora: ahora) == .unido)

        // ivan (member) intenta expulsar a sara (member).
        guard case .failure(let error) = try await casos.expulsar(tripId: tripId, memberId: sara, actor: ivan, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)
    }

    // 10. solo owner cierra/revoca: member intenta → .noAutorizado.
    @Test func soloOwnerCierra() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)
        #expect(try await casos.unirse(code: code, actor: ivan, ahora: ahora) == .unido)

        guard case .failure(let error) = try await casos.cerrar(tripId: tripId, actor: ivan, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)
    }

    @Test func soloOwnerRevoca() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)
        #expect(try await casos.unirse(code: code, actor: ivan, ahora: ahora) == .unido)

        guard case .failure(let error) = try await casos.revocar(code: code, tripId: tripId, actor: ivan, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)
    }

    // 11. no se puede expulsar al owner: owner intenta expulsarse por `expulsar` → reglaViolada.
    @Test func noSePuedeExpulsarAlOwner() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)
        #expect(try await casos.unirse(code: code, actor: ivan, ahora: ahora) == .unido)

        guard case .failure(let error) = try await casos.expulsar(tripId: tripId, memberId: ana, actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("no_se_expulsa_al_owner"))
    }

    // 12. invitar requiere membresía: no-miembro invita → .noAutorizado.
    @Test func invitarRequiereMembresia() async throws {
        let (casos, _) = entorno()
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora)

        guard case .failure(let error) = try await casos.invitar(tripId: viaje.id, actor: sara, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)
    }

    // Extra: cualquier miembro (no solo el owner) puede invitar (ADR-0018 §2).
    @Test func cualquierMiembroPuedeInvitar() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)
        #expect(try await casos.unirse(code: code, actor: ivan, ahora: ahora) == .unido)

        guard case .success = try await casos.invitar(tripId: tripId, actor: ivan, ahora: ahora) else {
            Issue.record("esperaba invitar exitoso"); return
        }
    }

    // Extra: salir es idempotente — un no-miembro que "sale" no es un error.
    @Test func salirEsIdempotente() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)
        #expect(try await casos.unirse(code: code, actor: ivan, ahora: ahora) == .unido)

        guard case .success = try await casos.salir(tripId: tripId, actor: ivan, ahora: ahora) else {
            Issue.record("esperaba salir exitoso"); return
        }
        // ivan ya no es miembro: detalle desde su punto de vista ahora es noAutorizado.
        guard case .failure(let error) = try await casos.detalle(tripId: tripId, actor: ivan) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)

        // Reintentar salir (ya no es miembro) sigue siendo éxito, no error.
        guard case .success = try await casos.salir(tripId: tripId, actor: ivan, ahora: ahora) else {
            Issue.record("salir debe ser idempotente"); return
        }
    }

    // Extra: invitar rechaza si el viaje está cerrado.
    @Test func invitarRechazaSiViajeCerrado() async throws {
        let (casos, _) = entorno()
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora)
        guard case .success = try await casos.cerrar(tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba cerrar exitoso"); return
        }
        guard case .failure(let error) = try await casos.invitar(tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .viajeCerrado)
    }

    // MARK: - Tope de listado (patrón chat: clamp [1,200] en el caso de uso)

    /// Un `limit` fuera de rango NUNCA se rechaza: se ajusta en silencio. 0 sube a 1,
    /// 999 baja a 200 (y con 3 viajes, 200 los devuelve todos).
    @Test func misViajesClampaElLimiteEnVezDeRechazarlo() async throws {
        let (casos, _) = entorno()
        for nombre in ["Roma", "Lisboa", "Oslo"] {
            _ = try await casos.crear(name: nombre, baseCurrency: "EUR", actor: ana, ahora: ahora)
        }

        #expect(try await casos.misViajes(actor: ana, limit: 0).count == 1)      // 0 -> 1
        #expect(try await casos.misViajes(actor: ana, limit: -5).count == 1)     // negativo -> 1
        #expect(try await casos.misViajes(actor: ana, limit: 999).count == 3)    // 999 -> 200 (caben los 3)
        #expect(try await casos.misViajes(actor: ana).count == 3)                // default 50
    }

    /// El orden debe ser TOTAL y repetible (por `id`, el mismo criterio que usa el
    /// adaptador Postgres desde este cambio): sin él, la página nº2 podría repetir u
    /// omitir viajes.
    @Test func misViajesTieneOrdenEstableYLaPaginaEsPrefijo() async throws {
        let (casos, _) = entorno()
        for nombre in ["Roma", "Lisboa", "Oslo"] {
            _ = try await casos.crear(name: nombre, baseCurrency: "EUR", actor: ana, ahora: ahora)
        }

        let completa = try await casos.misViajes(actor: ana, limit: 200).map(\.id)
        #expect(completa == completa.sorted())                                   // orden por id
        #expect(try await casos.misViajes(actor: ana, limit: 200).map(\.id) == completa)   // repetible
        #expect(try await casos.misViajes(actor: ana, limit: 2).map(\.id) == Array(completa.prefix(2)))
    }
}
