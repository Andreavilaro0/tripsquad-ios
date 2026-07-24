// Brújula IA (M8 Task 1, ADR-0023 borrador —
// docs/design/brujula-plan-stub.md). Puerto `AsistenteIA` + stub determinista:
// la ÚNICA frontera con el LLM externo. El dominio y `CasosDeUsoBrujula` no
// saben si detrás hay Anthropic, otro proveedor o el stub — mismo patrón de
// swap-in que `FotoStorage`/`FotoStorageStub` (ADR-0022).
//
// CERO gasto en autónomo (plan §Puerto): el `AsistenteStub` NO llama a
// ninguna API, NO tiene red, es determinista — sirve para probar el flujo y
// la autorización sin coste. El adaptador real es un swap-in cuando Andrea
// apruebe proveedor/presupuesto (muro duro) y traiga la doc vía Context7.

import Foundation

/// Contexto del viaje que se pasa al asistente. MVP: solo el resumen de
/// saldos (plan §Puerto: "RAG más rico [itinerario/votaciones/chat] = follow-up").
/// `resumenSaldos` es dato del sistema (números ya formateados por el
/// dominio), no texto libre de usuario — el riesgo de prompt-injection aquí
/// es bajo (plan §Dominio, nota de seguridad). Cuando el RAG incluya
/// chat/notas, el adaptador real debe tratarlos como input NO confiable.
public struct ContextoViaje: Equatable, Sendable {
    public let tripId: String
    public let resumenSaldos: String
    public init(tripId: String, resumenSaldos: String) {
        self.tripId = tripId
        self.resumenSaldos = resumenSaldos
    }
}

/// Puerto del asistente IA: la única frontera con el LLM externo. El
/// adaptador real (Anthropic recomendado, ADR-0023 provisional) implementará
/// este mismo protocolo sin que dominio ni casos de uso cambien.
public protocol AsistenteIA: Sendable {
    func responder(query: String, contexto: ContextoViaje) async throws -> String
}

/// Stub determinista para dev/tests: NO llama a ninguna API, NO gasta, NO
/// tiene estado ni reloj. Devuelve una respuesta canónica que refleja query +
/// contexto, útil para probar el flujo y la autorización de extremo a
/// extremo sin depender de (ni pagar) un LLM real.
public struct AsistenteStub: AsistenteIA {
    public init() {}

    public func responder(query: String, contexto: ContextoViaje) -> String {
        "[brújula-stub] Sobre \"\(query)\": \(contexto.resumenSaldos)"
    }
}

/// Errores de autorización/negocio de `CasosDeUsoBrujula`. `noAutorizado` es
/// deliberadamente el mismo error tanto si el actor no es miembro del viaje
/// como si el tripId no existe (mismo criterio "sin fuga de existencia" que
/// `ErrorItinerario`/`ErrorChat`/`ErrorFoto`, ADR-0018/ADR-0020/ADR-0021/ADR-0022).
public enum ErrorBrujula: Error, Equatable, Sendable {
    case noAutorizado
    case reglaViolada(String)
}
