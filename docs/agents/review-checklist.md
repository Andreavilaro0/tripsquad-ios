# Review Checklist — Fábrica TripSquad

Checklist versionado que TODO revisor de modelos (Codex, MiniMax, Gemini)
aplica a cada PR. Referenciado desde `README_AGENT.md`. Cambios a este archivo = PR normal.

Lentes prioritarias por revisor: Codex → seguridad (§2) · MiniMax → corrección y
dominio con visión (§1, §3) · Gemini → simplicidad y concisión (§6).
Todos aplican el checklist completo; la lente marca dónde profundizan.

## Formato del veredicto (obligatorio)

El revisor devuelve SIEMPRE este bloque estructurado:

```
VERDICT: APPROVE | REQUEST_CHANGES
CONFIDENCE: 1-10
BEAD: <id del bead>
FINDINGS:
- [BLOCKER|MAJOR|MINOR] <archivo:línea> — <hallazgo concreto>
SUMMARY: <2 frases máx: qué hace el PR y por qué el veredicto>
```

Regla: cualquier finding BLOCKER ⇒ REQUEST_CHANGES. Sin findings inventados:
si no hay problemas, FINDINGS queda vacío y se aprueba.

## 1. Corrección

- [ ] El diff hace lo que el bead pide — ni más (scope creep) ni menos (parcial).
- [ ] Casos borde: entradas vacías, nulos, concurrencia, offline.
- [ ] Errores manejados: nada de catch silencioso ni estados imposibles.
- [ ] Tests: el cambio trae los tests que su riesgo merece; pasan.

## 2. Seguridad (lente Codex prioritaria)

- [ ] Sin secretos, tokens, IPs internas o rutas personales en el diff.
- [ ] Entradas externas validadas (inyección, path traversal, deserialización).
- [ ] Sin dependencias nuevas no justificadas en el bead (supply chain).
- [ ] Permisos mínimos: nada pide más acceso del que necesita.
- [ ] OWASP top 10 cuando aplique (auth, session, crypto casero = BLOCKER).

## 3. Coherencia de dominio (el riesgo #1 señalado por Codex en el cold read)

- [ ] El cambio respeta el modelo de dominio de TripSquad (viajes, miembros,
      permisos de grupo, gastos/saldos, itinerario, votaciones, fotos).
- [ ] No inventa conceptos de dominio nuevos sin ADR.
- [ ] Nombres del dominio en el código = nombres del dominio en los docs.
- [ ] ¿Un cliente iOS consumiría esta API/estructura sin hacks? Si obliga a
      compensar con lógica rara en el cliente = MAJOR como mínimo.
- [ ] Consistente con los ADRs de `docs/decisions/` (append-only; no re-litigar).

## 4. Calidad estructural

- [ ] Clean Architecture: la capa correcta para cada cosa (cuando haya código).
- [ ] Tamaño de PR ≤400 líneas netas (README_AGENT).
- [ ] Sin comentarios que expliquen "qué hace la línea" — solo restricciones no obvias.
- [ ] Docs actualizados si el cambio los deja mentirosos.

## 5. Para PRs de documentación/ADR (research beads de F3)

- [ ] Afirmaciones con fuente (paper, doc oficial) — nada de memoria de modelo.
- [ ] ADR: contexto → decisión → consecuencias, corto, append-only.
- [ ] No contradice ADRs previos sin declararse superseding explícitamente.

## 6. Simplicidad y concisión (lente Gemini prioritaria)

Fundamento: *A Philosophy of Software Design* (Ousterhout) — la complejidad es
todo lo que hace el código difícil de entender o cambiar, y se combate con
módulos profundos e interfaces simples. *The Practice of Programming*
(Kernighan & Pike) — claridad primero. KISS / YAGNI.

- [ ] **Regla de las 3 líneas:** si el mismo comportamiento cabe en 3 líneas
      claras, 20 líneas son un defecto (MAJOR). Proponer la versión corta en el finding.
- [ ] Cero abstracciones especulativas: nada de interfaces, genéricos, capas o
      parámetros "por si acaso" sin un segundo uso real hoy (YAGNI).
- [ ] Módulos profundos: interfaz pequeña, implementación que hace el trabajo.
      Un helper que solo envuelve una llamada = inline y borrar.
- [ ] Sin duplicación con lo existente: ¿ya hay una función/patrón en el repo
      que hace esto? Reusar, no reinventar.
- [ ] Nombres que eliminan comentarios: si hace falta un comentario para
      explicar QUÉ hace, el nombre está mal.
- [ ] Control de flujo plano: early-return sobre anidación; nada de else tras return.
- [ ] La complejidad restante está justificada por un requisito real y se puede
      señalar cuál. Complejidad sin dueño = MAJOR.

**Severidad de §6:** la versión larga-pero-correcta no es BLOCKER (funciona);
es MAJOR con contrapropuesta concreta. Solo bloquea si además oculta un
defecto de §1-§4.
