// Modelos de onboarding: viajes, roles, miembros e invitaciones (ADR-0018).
// Igual que en el resto del módulo, son tipos puros — la autorización vive en
// `CasosDeUsoViaje`, no aquí.

import Foundation
import TripSquadDomain

/// Rol dentro de un viaje. El `owner` es quien lo creó; `member` es el resto.
/// "Owner ligero" (ADR-0018 §2): puede cerrar, expulsar y revocar invitaciones;
/// cualquier miembro (owner o member) puede invitar.
public enum RolMiembro: String, Sendable, Equatable {
    case owner
    case member
}

/// Un viaje. `closedAt != nil` es un rechazo permanente para toda mutación
/// (mismo patrón que `Membresia.viajeCerrado` en gastos/settle).
public struct Viaje: Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseCurrency: String     // ISO 4217; 'EUR' por defecto (ADR-0018 §6)
    public let createdBy: MiembroId
    public let closedAt: Date?
    public init(id: String, name: String, baseCurrency: String, createdBy: MiembroId, closedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.baseCurrency = baseCurrency
        self.createdBy = createdBy
        self.closedAt = closedAt
    }
}

/// Invitación por código (ADR-0018 §1/§4): multi-uso, caduca a 7 días,
/// revocable por el owner. El `code` es la PK de `trip_invites` — debe ser
/// aleatorio e imposible de adivinar (≥128 bits).
public struct Invitacion: Equatable, Sendable {
    public let code: String
    public let tripId: String
    public let createdBy: MiembroId
    public let expiresAt: Date
    public let revokedAt: Date?
    public init(code: String, tripId: String, createdBy: MiembroId, expiresAt: Date, revokedAt: Date? = nil) {
        self.code = code
        self.tripId = tripId
        self.createdBy = createdBy
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }
}

/// Resultado de canjear un código de invitación. Cada caso mapea 1:1 a una
/// razón de rechazo del plan — sin colapsar todo en un booleano, para que la
/// capa HTTP pueda dar un mensaje preciso sin adivinar.
public enum ResultadoUnirse: Equatable, Sendable {
    case unido
    case yaMiembro
    case codigoInvalido      // no existe
    case caducado
    case revocado
    case viajeCerrado
    case lleno               // tope de miembros alcanzado
}

/// Errores de autorización/negocio de `CasosDeUsoViaje`. `noAutorizado` es
/// deliberadamente el mismo error tanto si el actor no es miembro como si el
/// viaje no existe (ADR-0018: "no filtrar existencia a no-autorizados").
public enum ErrorViaje: Error, Equatable, Sendable {
    case noAutorizado
    case noEncontrado
    case viajeCerrado
    case reglaViolada(String)
}
