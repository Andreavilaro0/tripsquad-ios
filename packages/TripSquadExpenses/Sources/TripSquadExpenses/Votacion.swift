// Modelos de votaciones (M4, ADR-0019 borrador — docs/design/votaciones-scope-y-plan.md).
// Mismo patrón que `Viaje.swift`: tipos puros, la autorización vive en
// `CasosDeUsoVotacion`, no aquí.

import Foundation
import TripSquadDomain

/// Una votación de un viaje. `closedAt != nil` es un rechazo permanente para
/// votar (mismo patrón que `Viaje.closedAt` / `Membresia.viajeCerrado`).
public struct Votacion: Equatable, Sendable {
    public let id: String
    public let tripId: String
    public let question: String
    public let options: [String]        // ≥2, validado en el caso de uso al crear
    public let createdBy: MiembroId
    public let closedAt: Date?
    public init(id: String, tripId: String, question: String, options: [String], createdBy: MiembroId, closedAt: Date? = nil) {
        self.id = id
        self.tripId = tripId
        self.question = question
        self.options = options
        self.createdBy = createdBy
        self.closedAt = closedAt
    }
}

/// Detalle con resultados: conteo por opción + votantes (squad transparente,
/// provisional en el plan — no anónimo). `conteo` incluye SIEMPRE todas las
/// `options` de la votación, aunque tengan 0 votos, para que el cliente no
/// tenga que rellenar huecos.
public struct ResultadoVotacion: Equatable, Sendable {
    public let votacion: Votacion
    public let conteo: [String: Int]           // option -> nº votos
    public let votos: [(MiembroId, String)]    // quién votó qué (orden estable por MiembroId)
    public init(votacion: Votacion, conteo: [String: Int], votos: [(MiembroId, String)]) {
        self.votacion = votacion
        self.conteo = conteo
        self.votos = votos
    }

    // `[(MiembroId, String)]` no deriva Equatable (las tuplas no lo son de
    // fábrica): comparación miembro a miembro, en orden.
    public static func == (lhs: ResultadoVotacion, rhs: ResultadoVotacion) -> Bool {
        guard lhs.votacion == rhs.votacion, lhs.conteo == rhs.conteo, lhs.votos.count == rhs.votos.count else {
            return false
        }
        return zip(lhs.votos, rhs.votos).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

/// Resultado de emitir/cambiar un voto. Cada rechazo lleva su razón (poll no
/// encontrada, cerrada, option inválida) para que la capa HTTP no tenga que
/// adivinar el 422 (mismo espíritu que `ResultadoEscritura.rechazado`).
public enum ResultadoVotar: Equatable, Sendable {
    case registrado
    case rechazado(razon: String)
}

/// Errores de autorización/negocio de `CasosDeUsoVotacion`. `noAutorizado` es
/// deliberadamente el mismo error tanto si el actor no es miembro del viaje
/// como si la votación/el viaje no existen (mismo criterio "sin fuga de
/// existencia" que `ErrorViaje`, ADR-0018).
public enum ErrorVotacion: Error, Equatable, Sendable {
    case noAutorizado
    case noEncontrado
    case viajeCerrado
    case reglaViolada(String)
}
