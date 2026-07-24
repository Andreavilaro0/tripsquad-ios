// Casos de uso de la Brújula IA (M8 Task 1, ADR-0023 borrador —
// docs/design/brujula-plan-stub.md). La AUTORIZACIÓN es lo crítico de este
// archivo, mismo espíritu que `CasosDeUsoChat`/`CasosDeUsoFoto`. Stateless:
// sin migración, sin persistencia propia — cada consulta recalcula el
// contexto a partir de los gastos vigentes del viaje.
//
// Composición del init: mismo patrón mínimo que `CasosDeUsoChat` — dos
// fuentes de autorización/datos más el puerto del asistente:
//   - `repo: GastoRepositorio` -> gastos del viaje, para calcular saldos.
//   - `membresia: Membresia`   -> ¿el actor es miembro del viaje?
//   - `asistente: AsistenteIA` -> el LLM (stub hoy, adaptador real cuando se
//     decida proveedor/presupuesto — ADR-0023).

import Foundation
import TripSquadDomain

public struct CasosDeUsoBrujula: Sendable {
    private let repo: GastoRepositorio
    private let membresia: Membresia
    private let asistente: AsistenteIA

    /// Límite de longitud de la query (plan §Dominio): por encima se rechaza
    /// como `reglaViolada`, no se trunca — evita ambigüedad sobre qué parte
    /// de la pregunta llegó al asistente.
    private static let longitudMaximaQuery = 500

    public init(repo: GastoRepositorio, membresia: Membresia, asistente: AsistenteIA) {
        self.repo = repo
        self.membresia = membresia
        self.asistente = asistente
    }

    /// Solo miembros consultan (plan §Dominio, "403 sin fuga"). `query` es
    /// obligatoria: vacía (tras recortar espacios) o >500 caracteres se
    /// rechaza. Arma el `ContextoViaje` a partir de los saldos vigentes
    /// (`balances`, ADR-0011 §1) y delega la respuesta al `asistente`
    /// (stub o adaptador real, transparente para este caso de uso).
    public func consultar(tripId: String, query: String, actor: MiembroId) async throws -> Result<String, ErrorBrujula> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }

        let queryRecortada = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queryRecortada.isEmpty else { return .failure(.reglaViolada("query_vacia")) }
        guard queryRecortada.count <= Self.longitudMaximaQuery else { return .failure(.reglaViolada("query_muy_larga")) }

        let gastos = try await repo.gastos(de: tripId).map(\.gasto)
        let saldos = try balances(gastos)
        let contexto = ContextoViaje(tripId: tripId, resumenSaldos: Self.formatearResumenSaldos(saldos))

        let respuesta = try await asistente.responder(query: queryRecortada, contexto: contexto)
        return .success(respuesta)
    }

    /// Formatea los saldos netos en texto legible: "ana le deben 2000; ivan
    /// debe 2000" (positivo = le deben, negativo = debe, ADR-0011 §1). Los
    /// saldos en 0 no se listan (nada que reportar). Orden determinista por
    /// `MiembroId` (`Comparable`), igual criterio de estabilidad que
    /// `RepositorioEnMemoria.gastos(de:)`. Sin nadie a quien deber/le deban,
    /// "todo saldado".
    static func formatearResumenSaldos(_ saldos: [MiembroId: Int64]) -> String {
        let lineas = saldos
            .filter { $0.value != 0 }
            .sorted { $0.key < $1.key }
            .map { miembro, saldo -> String in
                saldo > 0 ? "\(miembro) le deben \(saldo)" : "\(miembro) debe \(-saldo)"
            }
        return lineas.isEmpty ? "todo saldado" : lineas.joined(separator: "; ")
    }
}
