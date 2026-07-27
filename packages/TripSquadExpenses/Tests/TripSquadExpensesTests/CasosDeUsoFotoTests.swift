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

    // 2c. caption demasiado larga → reglaViolada (bead mjp: campos de texto libre sin límite).
    @Test func presignConCaptionMuyLargaSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        let captionLarga = String(repeating: "a", count: 501)
        guard case .failure(let error) = try await casos.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, caption: captionLarga, actor: ana, ahora: ahora) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("caption_muy_larga"))
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
        let viaje = try await casosViaje.crear(name: "Roma", baseCurrency: "EUR", actor: ana, ahora: ahora).get()
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

    // Bead iou (Codex ronda 2): un NO-miembro no puede usar DELETE como oráculo — 403
    // uniforme, sin depender de si `fotoId` existe.
    @Test func borrarNoMiembroEsNoAutorizado() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())
        guard case .success(let presign) = try await casos.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("esperaba presign exitoso"); return
        }
        // sara no es miembro de t1: borra la foto de ana → noAutorizado, no 204.
        guard case .failure(let error) = try await casos.borrar(fotoId: presign.fotoId, tripId: "t1", actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)
        #expect(try await r.foto(id: presign.fotoId, en: "t1") != nil)   // sigue existiendo
    }

    // Bead iou (Codex ronda 2): un miembro que borra un `fotoId` que nunca existió EN SU
    // viaje, o que existe pero en OTRO viaje, obtiene éxito idempotente — nunca 403. La
    // respuesta es la MISMA en ambos casos (sin fuga), y no toca `storage` (no hay
    // `storageKey` que borrar).
    @Test func borrarFotoInexistenteOdeOtroViajeEsIdempotente() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        await r.anadirMiembro(ana, a: "t2")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        // Nunca existió en t1.
        guard case .success = try await casos.borrar(fotoId: "no-existe", tripId: "t1", actor: ana) else {
            Issue.record("esperaba borrar exitoso (idempotente) para foto inexistente"); return
        }

        // Existe, pero en OTRO viaje (t2) — borrarla "desde" t1 no debe filtrar que existe
        // en t2: mismo resultado, y sigue intacta en t2.
        guard case .success(let presignT2) = try await casos.presignSubida(tripId: "t2", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("esperaba presign exitoso en t2"); return
        }
        guard case .success = try await casos.borrar(fotoId: presignT2.fotoId, tripId: "t1", actor: ana) else {
            Issue.record("esperaba borrar exitoso (idempotente) para foto de otro viaje"); return
        }
        #expect(try await r.foto(id: presignT2.fotoId, en: "t2") != nil)   // sigue intacta en t2
    }

    // Viaje cerrado (decisión de la revisión integrada): SUBIR se bloquea (presign y
    // confirmar), BORRAR se permite — limpieza terminal, mismo criterio que itinerario.
    // Antes fotos era el único módulo mutante sin este gate y sin documentar por qué.
    @Test func viajeCerradoBloqueaSubirPeroNoBorrar() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())

        // Se sube una foto ANTES de cerrar, para poder probar el borrado después.
        guard case .success(let previa) = try await casos.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("esperaba presign exitoso antes de cerrar"); return
        }

        await r.cerrarViaje("t1")

        // Subir: bloqueado en las dos mitades.
        guard case .failure(let errorPresign) = try await casos.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("presign deberia fallar con el viaje cerrado"); return
        }
        #expect(errorPresign == .viajeCerrado)

        guard case .failure(let errorConfirmar) = try await casos.confirmar(fotoId: previa.fotoId, tripId: "t1", actor: ana) else {
            Issue.record("confirmar deberia fallar con el viaje cerrado"); return
        }
        #expect(errorConfirmar == .viajeCerrado)

        // Borrar: permitido (limpieza terminal).
        guard case .success = try await casos.borrar(fotoId: previa.fotoId, tripId: "t1", actor: ana) else {
            Issue.record("borrar SI debe permitirse con el viaje cerrado"); return
        }
        #expect(try await r.foto(id: previa.fotoId, en: "t1") == nil)
    }

    // Orden de borrado (bot GitHub M7 P2): PRIMERO el binario, DESPUÉS el metadato.
    // Con un storage que lanza al borrar el binario, el metadato NO debe borrarse:
    // la operación queda reintentable y no se pierde el puntero a un binario que sigue
    // existiendo. (Si el orden fuese metadato→binario, aquí el metadato ya no estaría
    // y el binario quedaría huérfano.)
    @Test func siElStorageFallaAlBorrarElMetadatoSeConserva() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: StorageQueLanzaAlBorrar())

        guard case .success(let presign) = try await casos.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("esperaba presign exitoso"); return
        }
        await confirmError { try await _ = casos.borrar(fotoId: presign.fotoId, tripId: "t1", actor: ana) }
        // El binario falló al borrarse → el metadato DEBE seguir (reintentable, sin huérfano).
        #expect(try await r.foto(id: presign.fotoId, en: "t1") != nil)
    }

    // MARK: - Tope de listado (patrón chat: clamp [1,200] en el caso de uso)

    /// Siembra 3 fotos `ready` con el MISMO `createdAt`: así el único desempate es el
    /// `id`, y además se cuenta cuántas URLs prefirmadas pide `listar`.
    private func conFotosListas(_ storage: FotoStorage) async throws -> (RepositorioEnMemoria, CasosDeUsoFoto) {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage)
        for _ in 0..<3 {
            guard case .success(let presign) = try await casos.presignSubida(
                tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora),
                  case .success = try await casos.confirmar(fotoId: presign.fotoId, tripId: "t1", actor: ana) else {
                Issue.record("esperaba presign + confirmar exitosos"); break
            }
        }
        return (r, casos)
    }

    /// Un `limit` fuera de rango NUNCA se rechaza: se ajusta en silencio. 0 sube a 1,
    /// 999 baja a 200 (y con 3 fotos, 200 las devuelve todas).
    @Test func listarClampaElLimiteEnVezDeRechazarlo() async throws {
        let (_, casos) = try await conFotosListas(storage())

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

    /// El orden debe ser TOTAL y repetible: con el mismo `createdAt`, el desempate es
    /// el `id` (mismo criterio que `ORDER BY created_at, id` en Postgres).
    @Test func listarTieneOrdenEstableYLaPaginaEsPrefijo() async throws {
        let (_, casos) = try await conFotosListas(storage())

        guard case .success(let completa) = try await casos.listar(tripId: "t1", actor: ana, limit: 200),
              case .success(let repetida) = try await casos.listar(tripId: "t1", actor: ana, limit: 200),
              case .success(let pagina) = try await casos.listar(tripId: "t1", actor: ana, limit: 2) else {
            Issue.record("esperaba listar exitoso"); return
        }
        let ids = completa.map(\.foto.id)
        #expect(ids == ids.sorted())          // mismo createdAt -> desempate por id
        #expect(repetida.map(\.foto.id) == ids)
        #expect(pagina.map(\.foto.id) == Array(ids.prefix(2)))
    }

    /// La razón de fondo del tope en FOTOS: `listar` pide UNA url prefirmada POR FOTO.
    /// Con `limit: 1` el storage debe recibir UNA sola llamada, no una por fila de la
    /// tabla — que era el coste real del listado sin tope.
    @Test func listarPideUnaUrlPrefirmadaPorFotoDevueltaNoPorFilaDeLaTabla() async throws {
        let contador = ContadorDeLecturas()
        let (_, casos) = try await conFotosListas(contador)

        guard case .success(let pagina) = try await casos.listar(tripId: "t1", actor: ana, limit: 1) else {
            Issue.record("esperaba listar exitoso"); return
        }
        #expect(pagina.count == 1)
        #expect(await contador.lecturas == 1, "3 fotos en la tabla, 1 en la página -> 1 prefirmada")
    }

    // Bead iou (Codex ronda 3, carrera TOCTOU): si el subidor es EXPULSADO mientras corre el
    // await de carga de la foto, el borrado (metadato + binario) NO debe completarse aunque
    // `uploadedBy` siga coincidiendo. El gate-oráculo pasa; la re-comprobación de membresía
    // tras la carga ve al ex-miembro y devuelve `.noAutorizado`. La foto sigue existiendo.
    @Test func expulsadoDuranteLaCargaNoBorra() async throws {
        let r = repo()
        await r.anadirMiembro(ana, a: "t1")
        let seed = CasosDeUsoFoto(repo: r, membresia: r, viajes: r, storage: storage())
        guard case .success(let presign) = try await seed.presignSubida(tripId: "t1", contentType: "image/jpeg", sizeBytes: 1024, actor: ana, ahora: ahora) else {
            Issue.record("esperaba presign exitoso"); return
        }
        let membresia = MembresiaExpulsaTrasPrimerCheck(real: r, expulsando: ana, de: "t1")
        let casos = CasosDeUsoFoto(repo: r, membresia: membresia, viajes: r, storage: storage())

        guard case .failure(let error) = try await casos.borrar(fotoId: presign.fotoId, tripId: "t1", actor: ana) else {
            Issue.record("esperaba .noAutorizado: expulsado durante la carga no debe poder borrar"); return
        }
        #expect(error == .noAutorizado)
        #expect(await r.foto(id: presign.fotoId, en: "t1") != nil)   // sigue existiendo
    }
}

/// Storage que cuenta cuántas URLs de LECTURA se han pedido — para demostrar que el
/// tope de `listar` acota las llamadas al proveedor, no solo el tamaño de la respuesta.
private actor ContadorDeLecturas: FotoStorage {
    private(set) var lecturas = 0
    func urlDeSubida(storageKey: String, contentType: String, expiraEn: TimeInterval) async throws -> String { "stub://subida/\(storageKey)" }
    func urlDeLectura(storageKey: String, expiraEn: TimeInterval) async throws -> String {
        lecturas += 1
        return "stub://lectura/\(storageKey)"
    }
    func borrar(storageKey: String) async throws {}
}

/// Storage que sube/lee como el stub pero LANZA al borrar el binario — para
/// probar el orden binario→metadato de `CasosDeUsoFoto.borrar`.
private struct StorageQueLanzaAlBorrar: FotoStorage {
    struct BorradoFallido: Error {}
    func urlDeSubida(storageKey: String, contentType: String, expiraEn: TimeInterval) async throws -> String { "stub://subida/\(storageKey)" }
    func urlDeLectura(storageKey: String, expiraEn: TimeInterval) async throws -> String { "stub://lectura/\(storageKey)" }
    func borrar(storageKey: String) async throws { throw BorradoFallido() }
}

/// Espera que el bloque lance; falla el test si no lanza.
private func confirmError(_ body: () async throws -> Void) async {
    do { try await body(); Issue.record("esperaba que lanzara") } catch { /* esperado */ }
}
