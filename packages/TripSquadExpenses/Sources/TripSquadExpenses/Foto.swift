// Modelos de fotos (M7 Task 1, ADR-0022 borrador —
// docs/design/fotos-plan-stub.md). Mismo patrón que `Itinerario.swift`/`Chat.swift`:
// tipos puros, la autorización vive en `CasosDeUsoFoto`, no aquí.
//
// El binario NUNCA pasa por el dominio: solo se guardan metadatos + una
// `storageKey` que apunta al object storage (real o stub). El puerto
// `FotoStorage` (en `Puertos.swift`) es la única frontera con el mundo
// externo — hoy implementada por `FotoStorageStub`, sin red ni credenciales.

import Foundation
import TripSquadDomain

/// Estado del ciclo de vida de una foto: `pending` tras el presign (el binario
/// aún no se ha subido/confirmado), `ready` tras `confirmar` (plan §Tareas).
public enum EstadoFoto: String, Sendable, Equatable {
    case pending
    case ready
}

/// Una foto de un viaje. El binario vive en el object storage bajo
/// `storageKey`; aquí solo el metadato. `sizeBytes` es opcional porque en el
/// presign se conoce el tamaño declarado por el cliente, no el real (el
/// adaptador real podría confirmarlo tras la subida).
public struct Foto: Equatable, Sendable {
    public let id: String
    public let tripId: String
    public let uploadedBy: MiembroId
    public let storageKey: String
    public let contentType: String
    public let sizeBytes: Int64?
    public let caption: String?
    public let status: EstadoFoto
    public let createdAt: Date

    public init(id: String, tripId: String, uploadedBy: MiembroId, storageKey: String, contentType: String, sizeBytes: Int64? = nil, caption: String? = nil, status: EstadoFoto = .pending, createdAt: Date) {
        self.id = id
        self.tripId = tripId
        self.uploadedBy = uploadedBy
        self.storageKey = storageKey
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.caption = caption
        self.status = status
        self.createdAt = createdAt
    }
}

/// Errores de autorización/negocio de `CasosDeUsoFoto`. `noAutorizado` es
/// deliberadamente el mismo error tanto si el actor no es miembro del viaje,
/// como si el tripId/photoId no existen, como si es miembro pero no es ni el
/// subidor ni el owner al borrar (mismo criterio "sin fuga de existencia" que
/// `ErrorItinerario`/`ErrorChat`, ADR-0018/ADR-0019/ADR-0020/ADR-0021).
public enum ErrorFoto: Error, Equatable, Sendable {
    case noAutorizado
    case noEncontrado
    case reglaViolada(String)
}
