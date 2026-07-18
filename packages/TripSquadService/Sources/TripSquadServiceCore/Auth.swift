// Extracción del actor (miembro autenticado) de la petición.
//
// ⚠️ STUB — el JWT real es un bead aparte (P0). Hoy el actor se lee de la cabecera
// `x-actor`. El diseño final (ADR-0009 §6, ADR-0014): Bearer JWT verificado contra
// las JWKS de Supabase, del que se extrae el `MiembroId`. La forma del handler no
// cambia cuando se sustituya el stub: sigue devolviendo un `MiembroId` o 401.

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain

extension Request {
    /// El miembro que hace la petición, o `nil` si no se pudo autenticar (→ 401).
    func actor() -> MiembroId? {
        // TODO(P0 auth): reemplazar por verificación de Bearer JWT (JWKS Supabase).
        guard let raw = headers[HTTPField.Name("x-actor")!]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        return MiembroId(raw)
    }

    /// La `Idempotency-Key` obligatoria en escrituras mutantes (guía §5).
    func idempotencyKey() -> String? {
        headers[HTTPField.Name("idempotency-key")!]
    }

    /// El ETag de `If-Match` (updates/deletes de recurso editable, ADR-0013).
    func ifMatch() -> String? {
        headers[.ifMatch]
    }
}
