// Modelos de itinerario (M5, ADR-0020 borrador —
// docs/design/itinerario-scope-y-plan.md). Mismo patrón que `Votacion.swift`:
// tipos puros, la autorización vive en `CasosDeUsoItinerario`, no aquí.

import Foundation
import TripSquadDomain

/// Una actividad del itinerario de un viaje. `day` es una fecha ISO
/// 'YYYY-MM-DD' en texto: el dominio no interpreta fechas, solo las guarda y
/// ordena lexicográficamente (mismo criterio que el plan §Contrato de dominio
/// — un ISO date ordena igual como string que como fecha).
public struct ActividadItinerario: Equatable, Sendable {
    public let id: String
    public let tripId: String
    public let title: String
    public let day: String              // ISO date 'YYYY-MM-DD'
    public let startTime: String?       // 'HH:mm' o nil
    public let location: String?
    public let notes: String?
    public let orderIndex: Int
    public let createdBy: MiembroId
    public init(id: String, tripId: String, title: String, day: String, startTime: String? = nil, location: String? = nil, notes: String? = nil, orderIndex: Int = 0, createdBy: MiembroId) {
        self.id = id
        self.tripId = tripId
        self.title = title
        self.day = day
        self.startTime = startTime
        self.location = location
        self.notes = notes
        self.orderIndex = orderIndex
        self.createdBy = createdBy
    }
}

/// Errores de autorización/negocio de `CasosDeUsoItinerario`. `noAutorizado`
/// es deliberadamente el mismo error tanto si el actor no es miembro del
/// viaje, como si la actividad/el viaje no existen, como si es miembro pero
/// no es ni el creador ni el owner al editar/borrar (mismo criterio "sin
/// fuga de existencia" que `ErrorViaje`/`ErrorVotacion`, ADR-0018/ADR-0019).
public enum ErrorItinerario: Error, Equatable, Sendable {
    case noAutorizado
    case noEncontrado
    case viajeCerrado
    case reglaViolada(String)
}
