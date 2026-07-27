// Adaptador en memoria del puerto `Idempotencia` (bead 379): claim-first + replay
// de la respuesta HTTP congelada, scopado por (actor, key). Es la referencia que
// el adaptador Postgres debe igualar, y el default de `Dependencias` en tests. Al
// ser un `actor`, `reclamar` muta el estado de forma atómica → dos peticiones
// concurrentes con la misma clave nunca ejecutan el efecto dos veces.

import Foundation
import TripSquadDomain

public actor IdempotenciaEnMemoria: Idempotencia {
    /// Estado por `(actor|key)`: reclamada-pero-en-vuelo vs respuesta ya congelada.
    /// Ausencia de clave = nunca vista.
    private enum Estado: Sendable { case enVuelo; case congelada(RespuestaCongelada) }
    private var estados: [String: Estado] = [:]

    public init() {}

    /// Scope por actor (ADR-0012 §5): un usuario no puede secuestrar la clave de otro.
    private func clave(_ actor: MiembroId, _ key: String) -> String { "\(actor.raw)|\(key)" }

    public func reclamar(actor: MiembroId, key: String) -> ReclamoIdempotencia {
        let k = clave(actor, key)
        switch estados[k] {
        case .none:
            estados[k] = .enVuelo          // reclama el hueco: nadie más re-ejecuta
            return .reclamado
        case .enVuelo:
            return .enVuelo
        case .congelada(let r):
            return .replay(r)
        }
    }

    public func congelar(actor: MiembroId, key: String, respuesta: RespuestaCongelada) {
        estados[clave(actor, key)] = .congelada(respuesta)
    }

    public func liberar(actor: MiembroId, key: String) {
        let k = clave(actor, key)
        if case .enVuelo = estados[k] { estados[k] = nil }   // solo libera lo NO congelado
    }
}
