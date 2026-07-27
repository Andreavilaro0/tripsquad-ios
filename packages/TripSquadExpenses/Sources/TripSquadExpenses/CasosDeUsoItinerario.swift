// Casos de uso de itinerario (M5, ADR-0020 borrador —
// docs/design/itinerario-scope-y-plan.md). La AUTORIZACIÓN es lo crítico de
// este archivo, mismo espíritu que `CasosDeUsoVotacion`.
//
// Composición del init: igual patrón que `CasosDeUsoVotacion` — dos fuentes
// de autorización que ya existen en el módulo, no se duplican:
//   - `membresia: Membresia`      -> ¿el actor es miembro del viaje? ¿está
//     cerrado?
//   - `viajes: ViajeRepositorio`  -> SOLO para `editar`/`borrar`, que
//     necesitan `rol(actor) == .owner` (la única fuente de verdad del rol
//     "owner ligero" de ADR-0018, no se reimplica aquí).
//   - `repo: ItinerarioRepositorio` -> persistencia de actividades.
//
// Regla transversal (mismo criterio que ADR-0018/ADR-0019): `crear`,
// `listar`, `editar` y `borrar` devuelven el MISMO `.noAutorizado` tanto si
// el actor no es miembro, como si el tripId/itemId no existen, como si es
// miembro pero no es ni el creador ni el owner — nunca se filtra existencia
// ni pertenencia a quien no tiene derecho a saberlo.

import Foundation
import TripSquadDomain

public struct CasosDeUsoItinerario: Sendable {
    private let repo: ItinerarioRepositorio
    private let membresia: Membresia
    private let viajes: ViajeRepositorio

    /// Topes de longitud (bead mjp, "campos de texto libre sin límite"): mismo
    /// criterio y unidad que `CasosDeUsoChat.enviar` (`unicodeScalars.count`
    /// == `char_length` de Postgres). `title`/`location` son títulos cortos;
    /// `notes` es texto libre más largo (mismo orden que `CasosDeUsoChat.body`).
    private static let longitudMaximaTitle = 200
    private static let longitudMaximaLocation = 200
    private static let longitudMaximaNotes = 4000

    public init(repo: ItinerarioRepositorio, membresia: Membresia, viajes: ViajeRepositorio) {
        self.repo = repo
        self.membresia = membresia
        self.viajes = viajes
    }

    /// Valida los topes de longitud de `title`/`location`/`notes`, compartido
    /// entre `crear` y `editar` (mismos campos, misma regla).
    private func validarLongitudes(title: String, location: String?, notes: String?) -> String? {
        guard title.unicodeScalars.count <= Self.longitudMaximaTitle else { return "title_muy_largo" }
        if let location, location.unicodeScalars.count > Self.longitudMaximaLocation { return "location_muy_larga" }
        if let notes, notes.unicodeScalars.count > Self.longitudMaximaNotes { return "notes_muy_largas" }
        return nil
    }

    /// Cualquier miembro puede añadir actividades (plan §1). Rechaza si el
    /// viaje está cerrado (misma coherencia que votaciones/onboarding/settle).
    /// `title` es obligatorio: vacío (tras recortar espacios) se rechaza.
    /// Devuelve la actividad CON su etag inicial (bead 201): no hay carrera
    /// que proteger al crear (fila nueva), pero el cliente lo necesita para el
    /// primer `If-Match` de una edición posterior.
    public func crear(tripId: String, title: String, day: String, startTime: String? = nil, location: String? = nil, notes: String? = nil, orderIndex: Int = 0, actor: MiembroId, ahora: Date) async throws -> Result<ActividadConEtag, ErrorItinerario> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.reglaViolada("title_vacio")) }
        if let codigo = validarLongitudes(title: title, location: location, notes: notes) { return .failure(.reglaViolada(codigo)) }
        let actividad = ActividadItinerario(id: UUID().uuidString, tripId: tripId, title: title, day: day, startTime: startTime, location: location, notes: notes, orderIndex: orderIndex, createdBy: actor)
        let conEtag = try await repo.crear(actividad, ahora: ahora)
        return .success(conEtag)
    }

    /// SOLO miembros listan (plan §3, "403 sin fuga"). El orden (day,
    /// orderIndex, id) es responsabilidad del repo (`listar`). `limit` se clampa a
    /// [1, 200] (mismo patrón que `CasosDeUsoChat.listar`): un límite fuera de rango
    /// NUNCA se rechaza, se ajusta en silencio. Cada item lleva su etag (bead 201).
    public func listar(tripId: String, actor: MiembroId, limit: Int = 50) async throws -> Result<[ActividadConEtag], ErrorItinerario> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        let limiteClamp = min(max(limit, 1), 200)
        return .success(try await repo.listar(tripId, limit: limiteClamp))
    }

    /// Una actividad concreta, con el MISMO gate que `listar` (solo miembros) y el
    /// mismo `.noAutorizado` sin fuga si no existe en ese viaje — observable idéntico
    /// a "buscarla dentro de `listar`", que es como lo hacía el PATCH de la ruta.
    ///
    /// Existe porque `listar` ya no devuelve el viaje entero: con tope, el PATCH de la
    /// actividad nº 201 habría empezado a dar 403 al no encontrarla en la primera
    /// página. Leer la fila directamente además quita un O(N) por PATCH.
    public func detalle(itemId: String, tripId: String, actor: MiembroId) async throws -> Result<ActividadItinerario, ErrorItinerario> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard let existente = try await repo.item(id: itemId, en: tripId) else { return .failure(.noAutorizado) }
        return .success(existente)
    }

    /// SOLO el creador de la actividad O el owner del viaje editan (plan §2,
    /// mismo criterio que cerrar votación). Se carga la actividad primero: si
    /// no existe (o pertenece a otro tripId), `.noAutorizado` — sin fuga de
    /// existencia. Rechaza si el viaje está cerrado (plan §5).
    ///
    /// `ifMatch` (bead 201, ADR-0013 mismo criterio que gastos): el UPDATE en
    /// el repo es condicional por etag y ATÓMICO (el WHERE compara el etag,
    /// no se lee-antes-de-escribir), así que dos PATCH concurrentes con el
    /// mismo `If-Match` no se pisan — el perdedor recibe `.conflicto` con el
    /// etag servidor actual. `.noEncontrado` del repo (carrera con un borrado
    /// entre la autorización y el UPDATE) se mapea a `.noAutorizado`, mismo
    /// criterio "sin fuga" que el resto de este archivo.
    public func editar(itemId: String, tripId: String, title: String, day: String, startTime: String? = nil, location: String? = nil, notes: String? = nil, orderIndex: Int = 0, actor: MiembroId, ifMatch: String, ahora: Date) async throws -> Result<ActividadConEtag, ErrorItinerario> {
        guard let existente = try await repo.item(id: itemId, en: tripId) else { return .failure(.noAutorizado) }
        // Debe ser miembro ACTUAL (Codex M5 P1): un ex-miembro que creó la actividad no puede
        // seguir editándola tras salir del viaje, aunque `createdBy` coincida. Se usa esMiembro
        // (consistente con crear/listar); en Postgres devuelve false si left_at != null.
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        let rolDelActor = try await viajes.rol(de: actor, en: tripId)
        guard existente.createdBy == actor || rolDelActor == .owner else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.reglaViolada("title_vacio")) }
        if let codigo = validarLongitudes(title: title, location: location, notes: notes) { return .failure(.reglaViolada(codigo)) }
        let actualizada = ActividadItinerario(id: existente.id, tripId: existente.tripId, title: title, day: day, startTime: startTime, location: location, notes: notes, orderIndex: orderIndex, createdBy: existente.createdBy)
        switch try await repo.actualizar(actualizada, ifMatch: ifMatch, ahora: ahora) {
        case .ok(let conEtag):
            return .success(conEtag)
        case .conflicto(let serverEtag):
            return .failure(.conflicto(serverEtag: serverEtag))
        case .noEncontrado:
            return .failure(.noAutorizado)
        }
    }

    /// SOLO el creador de la actividad O el owner del viaje borran (plan §2).
    /// El plan NO bloquea borrar en viaje cerrado (solo crear/editar, plan
    /// §5) — igual criterio que `CasosDeUsoVotacion.cerrar`: una acción
    /// terminal de limpieza no es una mutación de contenido.
    ///
    /// Enmienda ADR-0014 §2 (bead iou, hallazgo Codex ronda 2): el gate de
    /// membresía del `tripId` del path va SIEMPRE primero, ANTES de tocar el
    /// recurso — así un no-miembro nunca puede usar este endpoint como oráculo
    /// para sondear si `itemId` existe (aquí o en otro viaje). Una vez pasada
    /// la membresía, `itemId` inexistente EN ESTE viaje (nunca existió, ya se
    /// borró, o pertenece a OTRO viaje) es un no-op idempotente — `.success`,
    /// igual criterio que `RepositorioEnMemoria.eliminar` de gastos (ADR-0013
    /// §2: reintentar un borrado ya hecho no es error). Solo si la actividad
    /// SÍ existe en este viaje se evalúa "creador u owner"; si no lo es,
    /// `.noAutorizado` (403) — la respuesta nunca varía según si `itemId`
    /// existe en otro viaje.
    public func borrar(itemId: String, tripId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorItinerario> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }   // miembro ACTUAL (Codex M5 P1)
        guard let existente = try await repo.item(id: itemId, en: tripId) else { return .success(()) }   // idempotente, sin fuga (bead iou)
        let rolDelActor = try await viajes.rol(de: actor, en: tripId)
        guard existente.createdBy == actor || rolDelActor == .owner else { return .failure(.noAutorizado) }
        try await repo.borrar(id: itemId, en: tripId)
        return .success(())
    }
}
