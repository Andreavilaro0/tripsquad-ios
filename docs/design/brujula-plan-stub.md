# M8 — Brújula IA — Plan construible (puerto + STUB, sin gasto)

> Complementa `docs/design/brujula-ia-scope.md`. Construye TODO menos el adaptador LLM real:
> puerto `AsistenteIA` + **stub determinista** + ensamblado de contexto + endpoint. El adaptador
> Anthropic real es un swap-in cuando Andrea apruebe proveedor/presupuesto (muro duro) y traiga
> la doc vía Context7. **CERO gasto en autónomo.** ADR-0023 (provisional). Stack sobre M7.

## Puerto (la única frontera con el LLM externo)
```swift
public struct ContextoViaje: Equatable, Sendable {
    public let tripId: String
    public let resumenSaldos: String   // texto ya formateado (quién debe a quién / neto)
    // MVP: solo saldos. RAG más rico (itinerario/votaciones/chat) = follow-up.
}
public protocol AsistenteIA: Sendable {
    func responder(query: String, contexto: ContextoViaje) async throws -> String
}
/// Stub determinista para dev/tests: NO llama a ninguna API, NO gasta. Devuelve una respuesta
/// canónica que refleja query + contexto (útil para probar el flujo y la autorización).
public struct AsistenteStub: AsistenteIA {
    public func responder(query: String, contexto: ContextoViaje) -> String {
        "[brújula-stub] Sobre \"\(query)\": \(contexto.resumenSaldos)"
    }
}
```

## Dominio (TripSquadExpenses)
`CasosDeUsoBrujula(repo: GastoRepositorio, membresia: Membresia, asistente: AsistenteIA)`:
- `consultar(tripId, query, actor) async throws -> Result<String, ErrorBrujula>`:
  - `esMiembro(actor, tripId)` → si no, `.noAutorizado` (403 sin fuga).
  - query no vacía y ≤500 chars → si no, `.reglaViolada`.
  - Lee gastos del viaje (`repo.gastos(de:)`), calcula `balances`, formatea `resumenSaldos`
    (p.ej. "ana: +2000, ivan: -2000" o "nadie debe nada"), arma `ContextoViaje`.
  - `asistente.responder(query, contexto)` → `.success(respuesta)`.
- `ErrorBrujula`: `noAutorizado`, `reglaViolada(String)`.
- **Seguridad prompt-injection (para el adaptador real):** el `resumenSaldos` es dato del sistema
  (números), no texto libre de usuario, así que el riesgo es bajo aquí; cuando el RAG incluya
  chat/notas, el adaptador real debe tratarlos como input no confiable (documentar en 0023).

## Endpoint (Service)
- `POST /trips/:tripId/brujula` {query} → 200 {answer} · 403 no-miembro · 422 reglaViolada.
- Wire `casosBrujula: CasosDeUsoBrujula(repo: repo, membresia: repo, asistente: AsistenteStub())`.
- **Rate limiting** (acotar gasto del adaptador real): NO en el MVP con stub; se añade con el
  adaptador real (bead).

## Tareas
1. Dominio: `ContextoViaje` + puerto `AsistenteIA` + `AsistenteStub` + `CasosDeUsoBrujula` (lee gastos, calcula balances, formatea, llama asistente) + tests (consultar feliz devuelve texto con saldos, no-miembro 403 sin fuga, query vacía/larga → reglaViolada, saldos correctos en el contexto). Sin migración (stateless).
2. Service: endpoint POST /brujula + tests autorización.
3. Seguridad: revisión + arreglos.

## ADR-0023 (provisional)
Brújula = asistente que SUGIERE (no ejecuta escrituras), solo miembros, con contexto del viaje
(MVP: saldos). Proveedor LLM por decidir (Anthropic recomendado por las guías del repo) — se
construye con STUB, swap-in del adaptador real tras aprobación de gasto + doc vía Context7.
Prompt-injection, rate-limit y privacidad/RGPD a resolver con el adaptador real. Provisional.
