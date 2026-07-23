// Tests de fotos (M7 Task 1, ADR-0022 borrador). El foco es la AUTORIZACIÓN,
// la validación de tipo/tamaño en el presign y el filtro `soloListas` —
// mismo espíritu que CasosDeUsoItinerarioTests/CasosDeUsoChatTests.
//
// NOTA sobre el repo en memoria: `Membresia.esMiembro` y `ViajeRepositorio.rol`
// son DOS almacenes separados en `RepositorioEnMemoria` (ver nota de cabecera
// de CasosDeUsoItinerarioTests). El test de borrar por owner necesita el
// `rol` real de onboarding, así que monta el viaje con `CasosDeUsoViaje` y
// sincroniza los dos almacenes a mano.

import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Fotos: presign + confirmar + listar + borrar (M7 Task 1, ADR-0022 borrador)")
struct CasosDeUsoFotoTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan"), sara = MiembroId("sara")
    let ahora = Date(timeIntervalSince1970: 1_700_000_000)

    func repo() -> RepositorioEnMemoria { RepositorioEnMemoria() }
    func storage() -> FotoStorageStub { FotoStorageStub() }

    // 1. presign feliz: devuelve fotoId + url stub determinista, foto queda pending.
    @Test func presignFelizDevuelveFotoIdYUrlStub() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        guard case .success(let presign) = try await casos.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("esperaba presign exitoso"); return
        }
        #expect(!presign.fotoId.isEmpty)
        #expect(presign.urlSubida.hasPrefix("stub://"))
        #expect(presign.urlSubida.contains(presign.fotoId))

        let guardada = try await r.foto(id: presign.fotoId, en: "t1")
        #expect(guardada?.status == .pending)
        #expect(guardada?.uploadedBy == ana)
        #expect(guardada?.contentType == "image/jpeg")
    }

    // 2a. content-type no permitido → reglaViolada.
    @Test func presignConContentTypeInvalidoSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        guard case .failure(let error) = try await casos.presignSubida(tripId: "t1", contentType: "application/pdf", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("content_type_invalido"))
    }

    // 2b. tamaño superior a 20 MB → reglaViolada.
    @Test func presignConTamanoExcesivoSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        let veinteMasUno: Int64 = 20 * 1024 * 1024 + 1
        guard case .failure(let error) = try await casos.presignSubida(tripId: "t1", contentType: "image/png", sizeBytes: veinteMasUno, actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("size_invalido"))
    }

    // 3. no-miembro no puede presign ni listar: mismo error, sin fuga de existencia.
    @Test func noMiembroNoPresignNiListaSinFugaDeExistencia() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        guard case .failure(let errorPresign) = try await casos.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: sara, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorPresign == .noAutorizado)

        guard case .failure(let errorListar) = try await casos.listar(tripId: "t1", actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorListar == .noAutorizado)
    }

    // 4. confirmar marca ready y es idempotente.
    @Test func confirmarMarcaReadyYEsIdempotente() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        guard case .success(let presign) = try await casos.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("esperaba presign exitoso"); return
        }

        guard case .success = try await casos.confirmar(fotoId: presign.fotoId, tripId: "t1", actor: ana) else {
            Issue.record("esperaba confirmar exitoso"); return
        }
        #expect(try await r.foto(id: presign.fotoId, en: "t1")?.status == .ready)

        // Repetir la confirmación no falla (idempotente).
        guard case .success = try await casos.confirmar(fotoId: presign.fotoId, tripId: "t1", actor: ana) else {
            Issue.record("esperaba confirmar idempotente exitoso"); return
        }
    }

    // 5. listar solo devuelve fotos ready, cada una con su url.
    @Test func listarSoloDevuelveFotosReadyConUrl() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        guard case .success(let pendiente) = try await casos.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("esperaba presign exitoso"); return
        }
        guard case .success(let lista) = try await casos.presignSubida(tripId: "t1", contentType: "image/png", sizeBytes: 2048, actor: ana, ahora: ahora.addingTimeInterval(1)) else {
            Issue.record("esperaba presign exitoso"); return
        }
        guard case .success = try await casos.confirmar(fotoId: lista.fotoId, tripId: "t1", actor: ana) else {
            Issue.record("esperaba confirmar exitoso"); return
        }
        // `pendiente` se queda sin confirmar a propósito.

        guard case .success(let fotos) = try await casos.listar(tripId: "t1", actor: ana) else {
            Issue.record("esperaba listar exitoso"); return
        }
        #expect(fotos.map(\.foto.id) == [lista.fotoId])
        #expect(fotos[0].foto.status == .ready)
        #expect(!fotos[0].url.isEmpty)
        #expect(fotos.map(\.foto.id).contains(pendiente.fotoId) == false)
    }

    // 6. borrar: subidor ok, otro miembro no, owner sí.
    @Test func borrarSubidorOOwnerOtroMiembroNo() async throws {
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

        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        // ivan (member, NO owner) sube la foto → él es el subidor.
        guard case .success(let presignIvan) = try await casos.presignSubida(tripId: viaje.id, contentType: "image/jpeg", sizeBytes: 1024, actor: ivan, ahora: ahora) else {
            Issue.record("esperaba presign exitoso"); return
        }

        // sara (ni subidora ni owner) intenta borrar la foto de ivan → noAutorizado.
        guard case .failure(let errorSara) = try await casos.borrar(fotoId: presignIvan.fotoId, tripId: viaje.id, actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        #expect(errorSara == .noAutorizado)
        #expect(try await r.foto(id: presignIvan.fotoId, en: viaje.id) != nil)   // sigue existiendo

        // ivan (subidor, no owner) SÍ puede borrar su propia foto.
        guard case .success = try await casos.borrar(fotoId: presignIvan.fotoId, tripId: viaje.id, actor: ivan) else {
            Issue.record("esperaba borrar exitoso (subidor)"); return
        }
        #expect(try await r.foto(id: presignIvan.fotoId, en: viaje.id) == nil)

        // ana (owner, no subidora) también puede borrar una foto ajena.
        guard case .success(let presignSara) = try await casos.presignSubida(tripId: viaje.id, contentType: "image/heic", sizeBytes: 1024, actor: sara, ahora: ahora) else {
            Issue.record("esperaba presign exitoso"); return
        }
        guard case .success = try await casos.borrar(fotoId: presignSara.fotoId, tripId: viaje.id, actor: ana) else {
            Issue.record("esperaba borrar exitoso (owner)"); return
        }
        #expect(try await r.foto(id: presignSara.fotoId, en: viaje.id) == nil)
    }

    // Codex M5 P1 (mismo hallazgo aplicado aquí): un ex-miembro que subió la
    // foto NO puede borrarla tras salir del viaje, aunque `uploadedBy` coincida.
    @Test func exMiembroNoBorra() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        guard case .success(let presign) = try await casos.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("esperaba presign exitoso"); return
        }
        await r.quitarDeMembresia(ana, de: "t1")   // ana sale del viaje (uploadedBy sigue siendo ana)

        guard case .failure(let error) = try await casos.borrar(fotoId: presign.fotoId, tripId: "t1", actor: ana) else {
            Issue.record("borrar deberia fallar para ex-miembro"); return
        }
        #expect(error == .noAutorizado)
        #expect(try await r.foto(id: presign.fotoId, en: "t1") != nil)   // sigue existiendo
    }
}
