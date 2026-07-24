// Casos de uso de chat (M6, ADR-0021 borrador —
// docs/design/chat-scope-y-plan.md). La AUTORIZACIÓN es lo crítico de este
// archivo, mismo espíritu que `CasosDeUsoItinerario`.
//
// Composición del init: solo dos fuentes, más simple que Itinerario — el
// chat no tiene un rol "owner ligero" con permisos especiales (plan §3:
// borrar es SIEMPRE solo el autor, ni siquiera el owner del viaje puede
// borrar el mensaje de otro en este MVP):
//   - `repo: ChatRepositorio` -> persistencia de mensajes.
//   - `membresia: Membresia` -> ¿el actor es miembro del viaje?
//
// Regla transversal (mismo criterio que ADR-0018/ADR-0019/ADR-0020):
// `enviar`, `listar` y `borrar` devuelven el MISMO `.noAutorizado` tanto si
// el actor no es miembro, como si el tripId/messageId no existen, como si es
// miembro pero no es el autor del mensaje al borrar — nunca se filtra
// existencia ni pertenencia a quien no tiene derecho a saberlo.
//
// A diferencia de Itinerario/Votación, el chat NO bloquea nada en viaje
// cerrado (plan §Decisión 5, provisional: "el chat es memoria del viaje, no
// una mutación de contenido").

import Foundation
import TripSquadDomain

public struct CasosDeUsoChat: Sendable {
    private let repo: ChatRepositorio
    private let membresia: Membresia

    public init(repo: ChatRepositorio, membresia: Membresia) {
        self.repo = repo
        self.membresia = membresia
    }

    /// Cualquier miembro puede enviar (plan §Decisión 1). `body` es
    /// obligatorio: vacío (tras recortar espacios) o >4000 caracteres se
    /// rechaza (plan §Decisión 2).
    public func enviar(tripId: String, body: String, actor: MiembroId, ahora: Date) async throws -> Result<Mensaje, ErrorChat> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.reglaViolada("body_vacio")) }
        // El límite se mide en la MISMA unidad que la BD (bot GitHub M6 P2): Postgres
        // `char_length` cuenta code points (Unicode scalars), no grapheme clusters. Si
        // aquí usáramos `body.count` (grapheme clusters), un body de 4000 emojis bandera
        // (1 grapheme = 2 scalars) pasaría el dominio y REVENTARÍA el CHECK de la BD como
        // 5xx en vez de un 422 limpio. `unicodeScalars.count` == `char_length` de Postgres.
        guard body.unicodeScalars.count <= 4000 else { return .failure(.reglaViolada("body_muy_largo")) }
        let mensaje = try await repo.enviar(tripId: tripId, autor: actor, body: body, ahora: ahora)
        return .success(mensaje)
    }

    /// SOLO miembros listan (plan §Decisión 1, "403 sin fuga"). `limit` se
    /// clampa a [1, 200] (plan §Decisión 4) — nunca se rechaza por un límite
    /// fuera de rango, se ajusta en silencio. El orden cronológico y el
    /// filtro `id > since` son responsabilidad del repo (`mensajes`).
    public func listar(tripId: String, actor: MiembroId, since: Int64? = nil, limit: Int = 50) async throws -> Result<[Mensaje], ErrorChat> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        let limiteClamp = min(max(limit, 1), 200)
        return .success(try await repo.mensajes(tripId: tripId, since: since, limit: limiteClamp))
    }

    /// SOLO el autor del mensaje borra (plan §Decisión 3) — ni siquiera el
    /// owner del viaje, a diferencia de itinerario/votaciones. Se carga el
    /// mensaje primero: si no existe (o pertenece a otro tripId),
    /// `.noAutorizado` — sin fuga de existencia.
    public func borrar(msgId: Int64, tripId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorChat> {
        guard let existente = try await repo.mensaje(id: msgId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard existente.autor == actor else { return .failure(.noAutorizado) }
        try await repo.borrar(id: msgId, en: tripId, ahora: ahora)
        return .success(())
    }
}
