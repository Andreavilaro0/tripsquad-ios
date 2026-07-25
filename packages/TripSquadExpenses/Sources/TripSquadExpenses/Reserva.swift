// Modelos de "quién ya reservó" (wedge reserva por persona, spec
// docs/superpowers/specs/2026-07-25-wedge-reserva-por-persona-design.md). Mismo patrón que
// `Itinerario.swift`: tipos puros, la autorización vive en
// `CasosDeUsoReserva`, no aquí.

import Foundation
import TripSquadDomain

/// Tipo de actividad reservable.
public enum KindReserva: String, Sendable, Equatable, CaseIterable {
    case vuelo, hotel, coche, tren, seguro, otro
}

/// Estado de reserva de un miembro (o del responsable único).
public enum EstadoReserva: String, Sendable, Equatable {
    case pendiente, reservado
}

/// Cómo se reparte la reserva de una actividad entre los miembros del viaje.
public enum ModoReserva: Equatable, Sendable {
    /// Estados SOLO de los miembros incluidos (subconjunto elegido al crear).
    case cadaUnoElSuyo(estados: [MiembroId: EstadoReserva])
    /// Un responsable (nil = sin asignar) + un estado único.
    case unoParaTodos(responsable: MiembroId?, estado: EstadoReserva)
}

/// El aspecto "reserva" de una actividad de itinerario. Vive en su propio
/// almacén (no en `ActividadItinerario`): la actividad puede existir sin
/// reserva asociada.
public struct Reserva: Equatable, Sendable {
    public let activityId: String
    public let tripId: String
    public let kind: KindReserva
    public let mode: ModoReserva
    public init(activityId: String, tripId: String, kind: KindReserva, mode: ModoReserva) {
        self.activityId = activityId
        self.tripId = tripId
        self.kind = kind
        self.mode = mode
    }
}

/// Errores de autorización/negocio de `CasosDeUsoReserva`. Mismo criterio
/// "sin fuga de existencia" que `ErrorItinerario`/`ErrorVotacion`.
public enum ErrorReserva: Error, Equatable, Sendable {
    case noAutorizado
    case viajeCerrado
    case reglaViolada(String)
}
