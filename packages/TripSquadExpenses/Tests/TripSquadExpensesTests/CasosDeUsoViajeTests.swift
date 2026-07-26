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
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora).get()
        guard case .success(let invitacion) = try await casos.invitar(tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba invitar exitoso"); return (viaje.id, "")
        }
        return (viaje.id, invitacion.code)
    }

    // 1. crear → el creador es owner y miembro; aparece en misViajes.
    @Test func crearHaceAlCreadorOwnerYMiembro() async throws {
        let (casos, _) = entorno()
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora).get()
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
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora).get()

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
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora).get()

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
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora).get()
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
            _ = try await casos.crear(name: nombre, baseCurrency: "EUR", actor: ana, ahora: ahora).get()
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
            _ = try await casos.crear(name: nombre, baseCurrency: "EUR", actor: ana, ahora: ahora).get()
        }

        let completa = try await casos.misViajes(actor: ana, limit: 200).map(\.id)
        #expect(completa == completa.sorted())                                   // orden por id
        #expect(try await casos.misViajes(actor: ana, limit: 200).map(\.id) == completa)   // repetible
        #expect(try await casos.misViajes(actor: ana, limit: 2).map(\.id) == Array(completa.prefix(2)))
    }

    // P1 de la revisión integrada (ADR-0014 §2): expulsar revoca las invitaciones que el
    // expulsado emitió, EN LA MISMA operación. Sin esto reingresaba con su propio code.
    @Test func expulsarRevocaLasInvitacionesDelExpulsado() async throws {
        let (casos, _) = entorno()
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora).get()
        // ivan entra (con el code de ana) y a su vez invita: crea SU code.
        guard case .success(let inviteAna) = try await casos.invitar(tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba invitar de ana"); return
        }
        #expect(try await casos.unirse(code: inviteAna.code, actor: ivan, ahora: ahora) == .unido)
        guard case .success(let inviteIvan) = try await casos.invitar(tripId: viaje.id, actor: ivan, ahora: ahora) else {
            Issue.record("esperaba invitar de ivan"); return
        }

        // ana (owner) expulsa a ivan.
        guard case .success = try await casos.expulsar(tripId: viaje.id, memberId: ivan, actor: ana, ahora: ahora) else {
            Issue.record("esperaba expulsar exitoso"); return
        }

        // El code de ivan ya no vale: sara no puede entrar con él.
        #expect(try await casos.unirse(code: inviteIvan.code, actor: sara, ahora: ahora) == .revocado)
        // Y el propio ivan tampoco reingresa con su code.
        #expect(try await casos.unirse(code: inviteIvan.code, actor: ivan, ahora: ahora) == .revocado)
        // El code de ANA (otro emisor) sigue vivo — solo se revocan los del expulsado.
        #expect(try await casos.unirse(code: inviteAna.code, actor: sara, ahora: ahora) == .unido)
    }

    // MARK: - Sucesión de ownership al salir (enmienda ADR-0018, decisión de Andrea 2026-07-27)

    // 13. Sale el ÚLTIMO owner (ana) → el miembro activo más antiguo (ivan, que
    // entró antes que sara) pasa a owner. El viaje NUNCA queda sin owner.
    @Test func salirUltimoOwnerTransfiereAlMasAntiguo() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)
        #expect(try await casos.unirse(code: code, actor: ivan, ahora: ahora) == .unido)
        let masTarde = ahora.addingTimeInterval(60)
        #expect(try await casos.unirse(code: code, actor: sara, ahora: masTarde) == .unido)

        guard case .success = try await casos.salir(tripId: tripId, actor: ana, ahora: masTarde) else {
            Issue.record("esperaba salir exitoso"); return
        }

        guard case .success(let (_, miembros)) = try await casos.detalle(tripId: tripId, actor: ivan) else {
            Issue.record("esperaba detalle exitoso"); return
        }
        let porId = Dictionary(uniqueKeysWithValues: miembros)
        #expect(porId[ivan] == .owner)     // el más antiguo (excluyendo a ana) hereda
        #expect(porId[sara] == .member)    // sara no se toca
        #expect(porId[ana] == nil)         // ana ya no es miembro
        #expect(miembros.count == 2)       // el viaje NO se queda sin owner
    }

    // 14. Sale un owner cuando hay OTRO owner activo → no hay transferencia (ivan
    // conserva el rol que ya tenía, no lo gana por la salida de ana).
    @Test func salirOwnerConOtroOwnerNoTransfiere() async throws {
        let (casos, repo) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)
        #expect(try await casos.unirse(code: code, actor: ivan, ahora: ahora) == .unido)
        // Promueve a ivan a co-owner directamente en el repo — hoy no hay caso de uso
        // público para nombrar un segundo owner, así que se siembra el escenario aquí.
        try await repo.promoverAOwner(ivan, en: tripId)

        guard case .success = try await casos.salir(tripId: tripId, actor: ana, ahora: ahora) else {
            Issue.record("esperaba salir exitoso"); return
        }

        guard case .success(let (_, miembros)) = try await casos.detalle(tripId: tripId, actor: ivan) else {
            Issue.record("esperaba detalle exitoso"); return
        }
        let porId = Dictionary(uniqueKeysWithValues: miembros)
        #expect(porId[ivan] == .owner)   // ya lo era, sigue siéndolo — sin cambio
        #expect(porId[ana] == nil)       // ana ya no es miembro
        #expect(miembros.count == 1)
    }

    // 15. Sale un `member` (no owner) → nunca dispara sucesión, ana sigue owner sin cambios.
    @Test func salirMemberNoTransfiereOwnership() async throws {
        let (casos, _) = entorno()
        let (tripId, code) = try await viajeConInvitacion(casos)
        #expect(try await casos.unirse(code: code, actor: ivan, ahora: ahora) == .unido)

        guard case .success = try await casos.salir(tripId: tripId, actor: ivan, ahora: ahora) else {
            Issue.record("esperaba salir exitoso"); return
        }

        guard case .success(let (_, miembros)) = try await casos.detalle(tripId: tripId, actor: ana) else {
            Issue.record("esperaba detalle exitoso"); return
        }
        let porId = Dictionary(uniqueKeysWithValues: miembros)
        #expect(porId[ana] == .owner)
        #expect(miembros.count == 1)
    }

    // 16. Sale el owner siendo ÚNICO miembro del viaje → no falla, el viaje queda
    // sin miembros (a diferencia de "con miembros pero sin owner", eso SÍ es válido).
    @Test func salirOwnerUnicoMiembroDejaViajeSinMiembros() async throws {
        let (casos, _) = entorno()
        let viaje = try await casos.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora).get()

        guard case .success = try await casos.salir(tripId: viaje.id, actor: ana, ahora: ahora) else {
            Issue.record("esperaba salir exitoso"); return
        }

        guard case .failure(let error) = try await casos.detalle(tripId: viaje.id, actor: ana) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)
    }

    // MARK: - Topes de longitud (bead mjp: campos de texto libre sin límite)

    @Test func crearConNameMuyLargoSeRechaza() async throws {
        let (casos, _) = entorno()
        let nameLargo = String(repeating: "a", count: 201)
        guard case .failure(let error) = try await casos.crear(name: nameLargo, baseCurrency: "EUR", actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("name_muy_largo"))
    }

    @Test func crearConNameDe200CaracteresSeAcepta() async throws {
        let (casos, _) = entorno()
        let nameLimite = String(repeating: "a", count: 200)
        guard case .success(let viaje) = try await casos.crear(name: nameLimite, baseCurrency: "EUR", actor: ana, ahora: ahora) else {
            Issue.record("esperaba crear exitoso"); return
        }
        #expect(viaje.name.count == 200)
    }

    @Test func crearConBaseCurrencyMuyLargaSeRechaza() async throws {
        let (casos, _) = entorno()
        let monedaLarga = String(repeating: "a", count: 11)
        guard case .failure(let error) = try await casos.crear(name: "Roma", baseCurrency: monedaLarga, actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("base_currency_muy_largo"))
    }
}
