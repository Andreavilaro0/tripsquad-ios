// Casos de uso de fotos (M7 Task 1, ADR-0022 borrador —
// docs/design/fotos-plan-stub.md). La AUTORIZACIÓN es lo crítico de este
// archivo, mismo espíritu que `CasosDeUsoItinerario`/`CasosDeUsoChat`.
//
// Composición del init: mismo patrón que `CasosDeUsoItinerario` — tres
// fuentes de autorización/infra que ya existen, más el puerto de storage:
//   - `repo: FotoRepositorio`   -> persistencia de metadatos de fotos.
//   - `membresia: Membresia`    -> ¿el actor es miembro del viaje?
//   - `viajes: ViajeRepositorio` -> SOLO para `borrar`, que necesita
//     `rol(actor) == .owner` (la única fuente de verdad del rol "owner
//     ligero" de ADR-0018, no se reimplica aquí).
//   - `storage: FotoStorage`    -> URLs prefirmadas de subida/lectura y
//     borrado del binario (stub hoy, adaptador real cuando se decida el
//     proveedor — ADR-0022).
//
// Regla transversal (mismo criterio que ADR-0018/ADR-0019/ADR-0020/ADR-0021):
// `presignSubida`, `confirmar`, `listar` y `borrar` devuelven el MISMO
// `.noAutorizado` tanto si el actor no es miembro, como si el tripId/fotoId
// no existen, como si es miembro pero no es ni el subidor ni el owner al
// borrar — nunca se filtra existencia ni pertenencia a quien no tiene
// derecho a saberlo.

import Foundation
import TripSquadDomain

/// Resultado de un presign de subida (plan §Endpoints:
/// `POST .../photos/presign` -> `{photoId, uploadUrl, expiresIn}`).
public struct PresignSubida: Equatable, Sendable {
    public let fotoId: String
    public let urlSubida: String
    public let expiraEn: TimeInterval
    public init(fotoId: String, urlSubida: String, expiraEn: TimeInterval) {
        self.fotoId = fotoId
        self.urlSubida = urlSubida
        self.expiraEn = expiraEn
    }
}

/// Una foto lista para mostrar: metadato + URL prefirmada de LECTURA (plan
/// §Endpoints: `GET .../photos` -> `{id, uploadedBy, caption, url, createdAt}`).
public struct FotoConUrl: Equatable, Sendable {
    public let foto: Foto
    public let url: String
    public init(foto: Foto, url: String) {
        self.foto = foto
        self.url = url
    }
}

public struct CasosDeUsoFoto: Sendable {
    private let repo: FotoRepositorio
    private let membresia: Membresia
    private let viajes: ViajeRepositorio
    private let storage: FotoStorage

    /// Content-types permitidos para subir (plan §Tareas / fotos-scope.md
    /// §Autorización): solo estos tres formatos de imagen.
    private static let tiposPermitidos: Set<String> = ["image/jpeg", "image/png", "image/heic"]
    /// 20 MB (fotos-scope.md §Autorización).
    private static let tamanoMaximoBytes: Int64 = 20 * 1024 * 1024
    /// Caducidades de las URLs prefirmadas (fotos-scope.md §Autorización):
    /// 15 min para subir, 1 h para leer.
    private static let expiraSubida: TimeInterval = 15 * 60
    private static let expiraLectura: TimeInterval = 60 * 60

    public init(repo: FotoRepositorio, membresia: Membresia, viajes: ViajeRepositorio, storage: FotoStorage) {
        self.repo = repo
        self.membresia = membresia
        self.viajes = viajes
        self.storage = storage
    }

    /// Solo miembros piden presign (plan §Endpoints, "403 sin fuga"). Valida
    /// `contentType` (solo image/jpeg|png|heic) y `sizeBytes` (si se declara,
    /// > 0 y ≤ 20 MB) → `reglaViolada` si no cumple. Genera `id` (UUID) y
    /// `storageKey = "tripId/id"`, crea la `Foto` en `pending` y devuelve la
    /// URL prefirmada de subida que da el `storage` (stub o adaptador real).
    public func presignSubida(tripId: String, contentType: String, sizeBytes: Int64?, caption: String? = nil, actor: MiembroId, ahora: Date) async throws -> Result<PresignSubida, ErrorFoto> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard Self.tiposPermitidos.contains(contentType) else { return .failure(.reglaViolada("content_type_invalido")) }
        if let sizeBytes {
            guard sizeBytes > 0, sizeBytes <= Self.tamanoMaximoBytes else { return .failure(.reglaViolada("size_invalido")) }
        }
        let id = UUID().uuidString
        let storageKey = "\(tripId)/\(id)"
        let foto = Foto(id: id, tripId: tripId, uploadedBy: actor, storageKey: storageKey, contentType: contentType, sizeBytes: sizeBytes, caption: caption, status: .pending, createdAt: ahora)
        try await repo.crearPendiente(foto)
        let url = try await storage.urlDeSubida(storageKey: storageKey, contentType: contentType, expiraEn: Self.expiraSubida)
        return .success(PresignSubida(fotoId: id, urlSubida: url, expiraEn: Self.expiraSubida))
    }

    /// Solo miembros confirman (plan §Endpoints). Marca la foto `ready` —
    /// idempotente: repetir la confirmación de una foto ya `ready` sigue
    /// devolviendo éxito (mismo criterio de idempotencia que el resto del
    /// módulo). Si la foto no existe (o es de otro tripId), `.noAutorizado`
    /// — sin fuga de existencia.
    public func confirmar(fotoId: String, tripId: String, actor: MiembroId) async throws -> Result<Void, ErrorFoto> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard try await repo.marcarLista(id: fotoId, en: tripId) else { return .failure(.noAutorizado) }
        return .success(())
    }

    /// Solo miembros listan (plan §Endpoints, "403 sin fuga"). Solo devuelve
    /// fotos `ready` (las `pending`, sin binario confirmado, no se muestran),
    /// cada una con su URL prefirmada de LECTURA.
    public func listar(tripId: String, actor: MiembroId) async throws -> Result<[FotoConUrl], ErrorFoto> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        let fotos = try await repo.listar(tripId, soloListas: true)
        var resultado: [FotoConUrl] = []
        resultado.reserveCapacity(fotos.count)
        for foto in fotos {
            let url = try await storage.urlDeLectura(storageKey: foto.storageKey, expiraEn: Self.expiraLectura)
            resultado.append(FotoConUrl(foto: foto, url: url))
        }
        return .success(resultado)
    }

    /// SOLO el subidor de la foto O el owner del viaje borran (plan
    /// §Endpoints) — y el actor debe ser miembro ACTUAL (mismo hallazgo que
    /// M5/Codex P1: un ex-miembro que subió la foto no puede seguir
    /// borrándola tras salir del viaje, aunque `uploadedBy` coincida). Se
    /// carga la foto primero: si no existe (o pertenece a otro tripId),
    /// `.noAutorizado` — sin fuga de existencia. Borra metadato + binario.
    public func borrar(fotoId: String, tripId: String, actor: MiembroId) async throws -> Result<Void, ErrorFoto> {
        guard let existente = try await repo.foto(id: fotoId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }   // miembro ACTUAL
        let rolDelActor = try await viajes.rol(de: actor, en: tripId)
        guard existente.uploadedBy == actor || rolDelActor == .owner else { return .failure(.noAutorizado) }
        // Orden: PRIMERO el binario, DESPUÉS el metadato (bot GitHub M7 P2). Con un
        // FotoStorage real que puede lanzar, si borrásemos el metadato primero y el
        // binario fallase, el binario quedaría HUÉRFANO — fuga de storage sin puntero
        // para encontrarlo ni reintentar. Al revés, si falla el binario el metadato
        // sigue apuntando y la operación es reintentable; y si tras borrar el binario
        // falla el metadato, queda un puntero colgante (detectable y limpiable), nunca
        // un binario invisible que cuesta dinero para siempre.
        try await storage.borrar(storageKey: existente.storageKey)
        try await repo.borrar(fotoId: fotoId, en: tripId)
        return .success(())
    }
}
