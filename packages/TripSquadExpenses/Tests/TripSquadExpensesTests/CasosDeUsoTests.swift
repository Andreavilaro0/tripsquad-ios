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

    /// (bead 5ln) Misma Idempotency-Key + payload DISTINTO (request_hash distinto) → 422
    /// `idempotency_key_mismatch`, NO reproducir a ciegas. Mismo hash → replay normal.
    @Test func mismaClaveOtroPayloadEs422() async throws {
        let (casos, repo) = await nuevoEntorno()
        // 1ª vez: clave "k1" con hash "h1" → creado.
        let creado = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1", requestHash: "h1"))
        guard case .creado = creado else { Issue.record("esperaba creado, obtuve \(creado)"); return }

        // Misma clave + MISMO hash → replay (reproducido), no duplica.
        let mismoHash = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1", requestHash: "h1"))
        guard case .reproducido = mismoHash else { Issue.record("mismo hash debe reproducir, obtuve \(mismoHash)"); return }

        // Misma clave + OTRO hash (payload distinto) → rechazado idempotency_key_mismatch (422).
        let otroHash = try await casos.crear(.init(tripId: trip, gasto: gasto("g2"), actor: ana, idempotencyKey: "k1", requestHash: "h2"))
        guard case .rechazado(let razon) = otroHash else { Issue.record("otro hash debe rechazar, obtuve \(otroHash)"); return }
        #expect(razon == "idempotency_key_mismatch")
        // No creó el segundo gasto: la clave está ligada al 1er payload.
        #expect(await repo.gastos(de: trip).count == 1)
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

    /// (bead epb) El reparto incluye a alguien que NO es miembro del viaje:
    /// rechazado, no se persiste con un saldo colgado de un no-miembro.
    @Test func repartoConNoMiembroEsRechazado() async throws {
        let (casos, repo) = await nuevoEntorno()
        let malo = Gasto(id: "g1", pagadoPor: ana, importeMinor: 3000,
                         reparto: .igual(entre: [ana, sara]))
        let r = try await casos.crear(.init(tripId: trip, gasto: malo, actor: ana, idempotencyKey: "k1"))
        #expect(r == .rechazado(razon: "member_not_in_trip"))
        #expect(await repo.gastos(de: trip).isEmpty)
    }

    /// (bead epb) `pagadoPor` es alguien que NO es miembro del viaje: rechazado.
    @Test func pagadoPorNoMiembroEsRechazado() async throws {
        let (casos, repo) = await nuevoEntorno()
        let malo = Gasto(id: "g1", pagadoPor: sara, importeMinor: 3000,
                         reparto: .igual(entre: [ana, ivan]))
        let r = try await casos.crear(.init(tripId: trip, gasto: malo, actor: ana, idempotencyKey: "k1"))
        #expect(r == .rechazado(razon: "member_not_in_trip"))
        #expect(await repo.gastos(de: trip).isEmpty)
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

    /// (Codex P1) Replay antes de autorizar: si crea y LUEGO lo expulsan, el
    /// reintento con la misma clave devuelve la respuesta original, no un rechazo.
    @Test func replayGanaAunTrasExpulsion() async throws {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(ana, a: trip)
        await repo.anadirMiembro(ivan, a: trip)
        let casos = CasosDeUsoGastos(repo: repo, membresia: repo)
        let cmd = ComandoCrearGasto(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1")
        let primero = try await casos.crear(cmd)
        guard case .creado = primero else { Issue.record("esperaba creado"); return }
        // Ana deja de ser miembro (expulsada) entre intentos.
        let repoSinAna = RepositorioEnMemoria()  // no puede quitar miembro; simulamos con viaje cerrado
        _ = repoSinAna
        await repo.cerrarViaje(trip)
        // El reintento con la MISMA clave: replay, no "trip_closed".
        let segundo = try await casos.crear(cmd)
        guard case .reproducido = segundo else { Issue.record("esperaba reproducido, obtuve \(segundo)"); return }
    }

    /// (Codex P1) Un create con el id de un gasto ya borrado NO resucita la fila
    /// (tombstone, ADR-0013 §5): se rechaza como "deleted".
    @Test func createSobreTombstoneNoResucita() async throws {
        let (casos, repo) = await nuevoEntorno()
        _ = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        let etag = try #require(await repo.gasto(id: "g1", en: trip)).etag
        _ = try await casos.eliminar(.init(tripId: trip, gastoId: "g1", actor: ana, ifMatch: etag, idempotencyKey: "k2"))
        // Create rancio del mismo id con clave nueva -> no resucita.
        let r = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ivan, idempotencyKey: "k3"))
        #expect(r == .rechazado(razon: "deleted"))
        #expect(await repo.gastos(de: trip).isEmpty, "el tombstone no debe resucitar")
    }

    // MARK: - Historial de ediciones (p4b) + RGPD (o1v)

    /// Editar registra una revisión (ADR-0015 §15): el historial no está vacío
    /// tras un `editar`, y `edited_by` es el ACTOR que editó (no el pagador).
    @Test func editarRegistraRevision() async throws {
        let (casos, repo) = await nuevoEntorno()
        _ = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        let etag = try #require(await repo.gasto(id: "g1", en: trip)).etag
        _ = try await casos.editar(.init(tripId: trip, gasto: gasto("g1", importe: 5000),
                                         actor: ivan, ifMatch: etag, idempotencyKey: "k2"))
        let r = try await casos.revisiones(gastoId: "g1", tripId: trip, actor: ana)
        guard case .success(let revisiones) = r else { Issue.record("esperaba success"); return }
        #expect(revisiones.count == 1)
        #expect(revisiones.first?.editedBy == ivan)
    }

    /// Crear NO registra revisión (el historial es de EDICIONES, ADR-0015 §15) —
    /// solo `editar` escribe en `expense_revisions`.
    @Test func crearNoRegistraRevision() async throws {
        let (casos, _) = await nuevoEntorno()
        _ = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        let r = try await casos.revisiones(gastoId: "g1", tripId: trip, actor: ana)
        guard case .success(let revisiones) = r else { Issue.record("esperaba success"); return }
        #expect(revisiones.isEmpty)
    }

    /// Cualquier miembro ve el historial (autorización = is_member, ADR-0013 §4),
    /// no hace falta ser el autor de la edición.
    @Test func cualquierMiembroLeeElHistorial() async throws {
        let (casos, repo) = await nuevoEntorno()
        _ = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        let etag = try #require(await repo.gasto(id: "g1", en: trip)).etag
        _ = try await casos.editar(.init(tripId: trip, gasto: gasto("g1", importe: 5000),
                                         actor: ana, ifMatch: etag, idempotencyKey: "k2"))
        // Iván no editó nada, pero SÍ puede leer el historial (es miembro).
        let r = try await casos.revisiones(gastoId: "g1", tripId: trip, actor: ivan)
        guard case .success(let revisiones) = r else { Issue.record("esperaba success"); return }
        #expect(revisiones.count == 1)
    }

    /// No-miembro: `.noAutorizado`, sin fuga (mismo criterio que crear/editar).
    @Test func noMiembroNoLeeElHistorial() async throws {
        let (casos, _) = await nuevoEntorno()
        _ = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        let r = try await casos.revisiones(gastoId: "g1", tripId: trip, actor: sara)
        #expect(r == .failure(.noAutorizado))
    }

    /// `expenseId` inexistente (o de otro viaje): el MISMO `.noAutorizado`, sin
    /// fuga de existencia (mismo criterio que `CasosDeUsoItinerario.detalle`).
    @Test func gastoInexistenteDaNoAutorizado() async throws {
        let (casos, _) = await nuevoEntorno()
        let r = try await casos.revisiones(gastoId: "no-existe", tripId: trip, actor: ana)
        #expect(r == .failure(.noAutorizado))
    }

    /// RGPD (bead o1v, DECISIÓN de Andrea 2026-07-27): el derecho al olvido borra
    /// SOLO las revisiones del autor que lo ejerce; el gasto (de OTRO dueño) y las
    /// revisiones de OTROS autores sobreviven intactos.
    @Test func olvidarRevisionesBorraSoloLasDelAutor() async throws {
        let (casos, repo) = await nuevoEntorno()
        _ = try await casos.crear(.init(tripId: trip, gasto: gasto("g1"), actor: ana, idempotencyKey: "k1"))
        var etag = try #require(await repo.gasto(id: "g1", en: trip)).etag
        // Marta (aquí "ivan") edita la descripción de un gasto de Ana.
        _ = try await casos.editar(.init(tripId: trip, gasto: gasto("g1", importe: 4000),
                                         actor: ivan, ifMatch: etag, idempotencyKey: "k2"))
        etag = try #require(await repo.gasto(id: "g1", en: trip)).etag
        // Ana también edita (una revisión suya propia).
        _ = try await casos.editar(.init(tripId: trip, gasto: gasto("g1", importe: 4500),
                                         actor: ana, ifMatch: etag, idempotencyKey: "k3"))

        let borradas = try await casos.olvidarRevisionesDe(ivan)
        #expect(borradas == 1)

        let r = try await casos.revisiones(gastoId: "g1", tripId: trip, actor: ana)
        guard case .success(let revisiones) = r else { Issue.record("esperaba success"); return }
        #expect(revisiones.count == 1)
        #expect(revisiones.allSatisfy { $0.editedBy == ana })

        // El gasto de Ana sigue intacto: el olvido de Iván no lo tocó.
        let gastoSuperviviente = await repo.gasto(id: "g1", en: trip)
        #expect(gastoSuperviviente != nil)
    }

    /// (Codex P2) La clave de idempotencia se scopa por actor: dos usuarios con la
    /// misma clave determinista NO colisionan.
    @Test func claveIdempotenciaScopadaPorActor() async throws {
        let (casos, repo) = await nuevoEntorno()
        // Ana e Iván usan la MISMA clave "k" para gastos DISTINTOS.
        let ra = try await casos.crear(.init(tripId: trip, gasto: gasto("gA"), actor: ana, idempotencyKey: "k"))
        let ri = try await casos.crear(.init(tripId: trip, gasto: gasto("gB"), actor: ivan, idempotencyKey: "k"))
        guard case .creado = ra, case .creado = ri else {
            Issue.record("ambos deberían crearse: ana=\(ra), ivan=\(ri)"); return
        }
        #expect(await repo.gastos(de: trip).count == 2, "Iván no debe recibir el replay de Ana")
    }
}
