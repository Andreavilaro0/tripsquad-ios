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

    public init(repo: ItinerarioRepositorio, membresia: Membresia, viajes: ViajeRepositorio) {
        self.repo = repo
        self.membresia = membresia
        self.viajes = viajes
    }

    /// Cualquier miembro puede añadir actividades (plan §1). Rechaza si el
    /// viaje está cerrado (misma coherencia que votaciones/onboarding/settle).
    /// `title` es obligatorio: vacío (tras recortar espacios) se rechaza.
    public func crear(tripId: String, title: String, day: String, startTime: String? = nil, location: String? = nil, notes: String? = nil, orderIndex: Int = 0, actor: MiembroId, ahora: Date) async throws -> Result<ActividadItinerario, ErrorItinerario> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.reglaViolada("title_vacio")) }
        let actividad = ActividadItinerario(id: UUID().uuidString, tripId: tripId, title: title, day: day, startTime: startTime, location: location, notes: notes, orderIndex: orderIndex, createdBy: actor)
        try await repo.crear(actividad, ahora: ahora)
        return .success(actividad)
    }

    /// SOLO miembros listan (plan §3, "403 sin fuga"). El orden (day,
    /// orderIndex) es responsabilidad del repo (`listar`).
    public func listar(tripId: String, actor: MiembroId) async throws -> Result<[ActividadItinerario], ErrorItinerario> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        return .success(try await repo.listar(tripId))
    }

    /// SOLO el creador de la actividad O el owner del viaje editan (plan §2,
    /// mismo criterio que cerrar votación). Se carga la actividad primero: si
    /// no existe (o pertenece a otro tripId), `.noAutorizado` — sin fuga de
    /// existencia. Rechaza si el viaje está cerrado (plan §5).
    public func editar(itemId: String, tripId: String, title: String, day: String, startTime: String? = nil, location: String? = nil, notes: String? = nil, orderIndex: Int = 0, actor: MiembroId, ahora: Date) async throws -> Result<ActividadItinerario, ErrorItinerario> {
        guard let existente = try await repo.item(id: itemId, en: tripId) else { return .failure(.noAutorizado) }
        let rolDelActor = try await viajes.rol(de: actor, en: tripId)
        guard existente.createdBy == actor || rolDelActor == .owner else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.reglaViolada("title_vacio")) }
        let actualizada = ActividadItinerario(id: existente.id, tripId: existente.tripId, title: title, day: day, startTime: startTime, location: location, notes: notes, orderIndex: orderIndex, createdBy: existente.createdBy)
        try await repo.actualizar(actualizada, ahora: ahora)
        return .success(actualizada)
    }

    /// SOLO el creador de la actividad O el owner del viaje borran (plan §2).
    /// El plan NO bloquea borrar en viaje cerrado (solo crear/editar, plan
    /// §5) — igual criterio que `CasosDeUsoVotacion.cerrar`: una acción
    /// terminal de limpieza no es una mutación de contenido.
    public func borrar(itemId: String, tripId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorItinerario> {
        guard let existente = try await repo.item(id: itemId, en: tripId) else { return .failure(.noAutorizado) }
        let rolDelActor = try await viajes.rol(de: actor, en: tripId)
        guard existente.createdBy == actor || rolDelActor == .owner else { return .failure(.noAutorizado) }
        try await repo.borrar(id: itemId, en: tripId)
        return .success(())
    }
}
