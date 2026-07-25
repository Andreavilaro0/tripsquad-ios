// Caso de uso del wedge "quién ya reservó" (spec
// docs/superpowers/specs/2026-07-25-wedge-reserva-por-persona-design.md). La AUTORIZACIÓN calca el
// gate de `CasosDeUsoItinerario.editar/borrar`: se carga primero la
// actividad (sin fuga de existencia si no está), luego se exige miembro
// ACTUAL, y solo el creador de la actividad o el owner del viaje pueden
// definir/quitar el aspecto reserva.
//
// `marcar` tiene su propio gate porque autoriza sobre la RESERVA (no sobre
// la actividad): en `cadaUnoElSuyo` cada miembro marca su propio estado (o
// el owner marca el de cualquiera); en `unoParaTodos` solo el responsable
// (o el owner) marca el estado único.

import Foundation
import TripSquadDomain

public struct CasosDeUsoReserva: Sendable {
    private let repo: ReservaRepositorio
    private let itinerario: ItinerarioRepositorio
    private let membresia: Membresia
    private let viajes: ViajeRepositorio

    public init(repo: ReservaRepositorio, itinerario: ItinerarioRepositorio, membresia: Membresia, viajes: ViajeRepositorio) {
        self.repo = repo
        self.itinerario = itinerario
        self.membresia = membresia
        self.viajes = viajes
    }

    /// Marca una actividad como reservable (crea/edita el aspecto). SOLO el
    /// creador de la actividad o el owner del viaje (mismo gate que
    /// `CasosDeUsoItinerario.editar`). `participantes` solo aplica a
    /// `cadaUnoElSuyo` (debe ser un subconjunto no vacío de los miembros
    /// actuales); `responsable` solo a `unoParaTodos` (si no es `nil`, debe
    /// ser miembro actual).
    public func definir(tripId: String, activityId: String, kind: KindReserva,
                        modo: ModoDefinicion, actor: MiembroId, ahora: Date) async throws -> Result<Reserva, ErrorReserva> {
        guard let act = try await itinerario.item(id: activityId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        let rol = try await viajes.rol(de: actor, en: tripId)
        guard act.createdBy == actor || rol == .owner else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }

        let miembros = Set(try await viajes.miembros(de: tripId).map { $0.0 })
        let mode: ModoReserva
        switch modo {
        case .cadaUnoElSuyo(let participantes):
            guard !participantes.isEmpty else { return .failure(.reglaViolada("sin_participantes")) }
            guard participantes.allSatisfy({ miembros.contains($0) }) else { return .failure(.reglaViolada("participante_no_miembro")) }
            mode = .cadaUnoElSuyo(estados: Dictionary(uniqueKeysWithValues: participantes.map { ($0, .pendiente) }))
        case .unoParaTodos(let responsable):
            if let resp = responsable, !miembros.contains(resp) { return .failure(.reglaViolada("responsable_no_miembro")) }
            mode = .unoParaTodos(responsable: responsable, estado: .pendiente)
        }
        let reserva = Reserva(activityId: activityId, tripId: tripId, kind: kind, mode: mode)
        try await repo.upsert(reserva, ahora: ahora)
        return .success(reserva)
    }

    /// Quita el aspecto reserva. Mismo gate que `definir` (creador de la
    /// actividad u owner del viaje). Idempotente vía `repo.borrar` (borrar
    /// algo que no existe no es error).
    public func quitar(tripId: String, activityId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorReserva> {
        guard let act = try await itinerario.item(id: activityId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        let rol = try await viajes.rol(de: actor, en: tripId)
        guard act.createdBy == actor || rol == .owner else { return .failure(.noAutorizado) }
        try await repo.borrar(activityId: activityId, en: tripId)
        return .success(())
    }

    /// Marca estado. `cadaUnoElSuyo`: `memberId` no-nil y debe estar incluido
    /// en el aspecto reserva; actor == memberId O owner. `unoParaTodos`:
    /// `memberId == nil`; actor == responsable O owner.
    public func marcar(tripId: String, activityId: String, memberId: MiembroId?, estado: EstadoReserva,
                       actor: MiembroId, ahora: Date) async throws -> Result<Reserva, ErrorReserva> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard let reserva = try await repo.reserva(activityId: activityId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }
        let esOwner = (try await viajes.rol(de: actor, en: tripId)) == .owner

        switch reserva.mode {
        case .cadaUnoElSuyo(let estados):
            guard let m = memberId else { return .failure(.reglaViolada("falta_member_id")) }
            guard estados[m] != nil else { return .failure(.reglaViolada("miembro_no_incluido")) }
            guard actor == m || esOwner else { return .failure(.noAutorizado) }
            try await repo.marcarEstado(activityId: activityId, en: tripId, miembro: m, estado: estado)
        case .unoParaTodos(let responsable, _):
            guard responsable != nil else { return .failure(.reglaViolada("sin_responsable")) }
            guard memberId == nil else { return .failure(.reglaViolada("member_id_sobra")) }
            guard actor == responsable || esOwner else { return .failure(.noAutorizado) }
            try await repo.marcarEstado(activityId: activityId, en: tripId, miembro: nil, estado: estado)
        }
        guard let actualizada = try await repo.reserva(activityId: activityId, en: tripId) else { return .failure(.noAutorizado) }
        return .success(actualizada)
    }

    /// El tablero. Solo miembros del viaje.
    public func tablero(tripId: String, actor: MiembroId) async throws -> Result<[Reserva], ErrorReserva> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        return .success(try await repo.tablero(tripId))
    }
}

/// Entrada de `definir`: separa la elección de participantes/responsable de
/// los estados internos (que siempre arrancan `.pendiente`, el caso de uso
/// no deja que el llamador los fije al crear).
public enum ModoDefinicion: Equatable, Sendable {
    case cadaUnoElSuyo(participantes: [MiembroId])
    case unoParaTodos(responsable: MiembroId?)
}
