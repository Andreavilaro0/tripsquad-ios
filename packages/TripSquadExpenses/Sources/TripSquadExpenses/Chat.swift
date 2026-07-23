// Modelos de chat (M6, ADR-0021 borrador —
// docs/design/chat-scope-y-plan.md). Mismo patrón que `Itinerario.swift`:
// tipos puros, la autorización vive en `CasosDeUsoChat`, no aquí.
//
// MVP: solo el almacén de mensajes + lectura por polling (cursor `since`).
// El realtime (transporte) es MURO DURO — no se decide ni se implementa aquí.

import Foundation
import TripSquadDomain

/// Un mensaje de chat de un viaje. `id` es un cursor monotónico (creciente,
/// global — no reinicia por viaje) que sirve tanto de identificador como de
/// paginación (`since`, plan §4). Borrar es soft-delete: `deletedAt` queda
/// puesto y el `body` original se sustituye por un marcador (plan §Decisión 3)
/// — el mensaje NO desaparece de la lista, para no romper el hilo de la
/// conversación de los demás miembros.
public struct Mensaje: Equatable, Sendable {
    public let id: Int64
    public let tripId: String
    public let autor: MiembroId
    public let body: String
    public let deletedAt: Date?
    public let createdAt: Date
    public init(id: Int64, tripId: String, autor: MiembroId, body: String, deletedAt: Date? = nil, createdAt: Date) {
        self.id = id
        self.tripId = tripId
        self.autor = autor
        self.body = body
        self.deletedAt = deletedAt
        self.createdAt = createdAt
    }

    /// Marcador que sustituye al `body` original cuando el mensaje se borra
    /// (plan §Decisión 3): el mensaje no desaparece del hilo, pero su
    /// contenido sí se descarta.
    public static let marcadorBorrado = "[mensaje eliminado]"
}

/// Resultado de enviar un mensaje: éxito con el `Mensaje` creado, o rechazo
/// con la razón (validación de `body`, plan §Decisión 2). La autorización
/// (no-miembro) se modela aparte con `ErrorChat`, no aquí — mismo criterio
/// que separar `ResultadoEscritura`/errores de autorización en el resto del
/// módulo.
public enum ResultadoEnviar: Equatable, Sendable {
    case enviado(Mensaje)
    case rechazado(razon: String)
}

/// Errores de autorización/negocio de `CasosDeUsoChat`. `noAutorizado` es
/// deliberadamente el mismo error tanto si el actor no es miembro del viaje,
/// como si el mensaje/viaje no existen, como si es miembro pero no es el
/// autor del mensaje al borrar (mismo criterio "sin fuga de existencia" que
/// `ErrorItinerario`/`ErrorVotacion`, ADR-0018/ADR-0019/ADR-0020).
public enum ErrorChat: Error, Equatable, Sendable {
    case noAutorizado
    case noEncontrado
    case reglaViolada(String)
}
