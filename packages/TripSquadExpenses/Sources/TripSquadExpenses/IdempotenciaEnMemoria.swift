// Adaptador en memoria del puerto `Idempotencia` (bead 379): claim-first + replay
// de la respuesta HTTP congelada, scopado por (actor, key). Es la referencia que
// el adaptador Postgres debe igualar, y el default de `Dependencias` en tests. Al
// ser un `actor`, `reclamar` muta el estado de forma atómica → dos peticiones
// concurrentes con la misma clave nunca ejecutan el efecto dos veces.

import Foundation
import TripSquadDomain

public actor IdempotenciaEnMemoria: Idempotencia {
    /// Estado por `(actor|key)`: reclamada-pero-en-vuelo vs respuesta ya congelada. Ambos
    /// llevan el `requestHash` de la 1ª reclamación (bead 5ln): un reintento con la misma
    /// clave pero hash distinto es un payload distinto → `.payloadDistinto` (→ 422).
    /// Ausencia de clave = nunca vista.
    private enum Estado: Sendable { case enVuelo(String); case congelada(RespuestaCongelada, String) }
    private var estados: [String: Estado] = [:]

    public init() {}

    /// Scope por actor (ADR-0012 §5): un usuario no puede secuestrar la clave de otro.
    private func clave(_ actor: MiembroId, _ key: String) -> String { "\(actor.raw)|\(key)" }

    public func reclamar(actor: MiembroId, key: String, requestHash: String) -> ReclamoIdempotencia {
        let k = clave(actor, key)
        switch estados[k] {
        case .none:
            estados[k] = .enVuelo(requestHash)   // reclama el hueco: nadie más re-ejecuta
            return .reclamado
        case .enVuelo(let h):
            return h == requestHash ? .enVuelo : .payloadDistinto
        case .congelada(let r, let h):
            return h == requestHash ? .replay(r) : .payloadDistinto
        }
    }

    public func congelar(actor: MiembroId, key: String, respuesta: RespuestaCongelada) {
        let k = clave(actor, key)
        // Conserva el hash de la reclamación (`reclamar` lo dejó en `.enVuelo`); si por lo
        // que sea no había reclamo previo, cae a "" (misma laxitud que la conveniencia sin hash).
        let hash: String
        switch estados[k] {
        case .enVuelo(let h): hash = h
        case .congelada(_, let h): hash = h
        case .none: hash = ""
        }
        estados[k] = .congelada(respuesta, hash)
    }

    public func liberar(actor: MiembroId, key: String) {
        let k = clave(actor, key)
        if case .enVuelo(_) = estados[k] { estados[k] = nil }   // solo libera lo NO congelado
    }
}
