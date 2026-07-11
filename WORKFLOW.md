---
# Fábrica TripSquad — workflow del despachador Sortie
# Fuente de verdad de tickets: Beads (bd). Este tracker `file` lee el export
# generado por scripts/beads-to-sortie.py — Sortie nunca escribe en él.
# active_states incluye in_progress (review Codex P2): el agente reclama el
# bead nada más empezar (open → in_progress) y la reconciliación de Sortie
# debe seguir viéndolo activo para permitir turnos de continuación.
# Los beads open-pero-bloqueados los exporta el puente como `blocked`.
tracker:
  kind: file
  active_states:
    - open
    - in_progress
  terminal_states:
    - closed

file:
  path: .sortie/issues.json

polling:
  interval_ms: 300000

agent:
  kind: claude-code
  command: claude
  max_turns: 8
  max_sessions: 2
  max_concurrent_agents: 1
  max_tokens: 400000

db_path: .sortie/sortie.db

# Los hooks corren DENTRO del workspace por-issue, no en el repo del
# despachador (review Codex P1). Por eso:
#  - after_create clona el repo en el workspace para que el agente tenga código
#  - el puente se invoca por ruta estable FUERA del workspace, en el clon del
#    despachador: $SORTIE_FABRICA_REPO (heredado por empezar por SORTIE_) con
#    fallback a ~/fabrica/tripsquad-ios (la ruta del Pi)
hooks:
  after_create: |
    git clone --branch develop https://github.com/Andreavilaro0/tripsquad-ios.git "$SORTIE_WORKSPACE"
  before_run: |
    FABRICA="${SORTIE_FABRICA_REPO:-$HOME/fabrica/tripsquad-ios}"
    python3 "$FABRICA/scripts/beads-to-sortie.py"
  after_run: |
    FABRICA="${SORTIE_FABRICA_REPO:-$HOME/fabrica/tripsquad-ios}"
    python3 "$FABRICA/scripts/beads-to-sortie.py"
---

Eres un agente de la Fábrica TripSquad. Trabaja este ticket obedeciendo
`README_AGENT.md` y `constitution.md` del repo (léelos antes de tocar nada).

**{{ .issue.identifier }}**: {{ .issue.title }}

{{ if .issue.description }}
## Descripción
{{ .issue.description }}
{{ end }}

## Reglas críticas (resumen — el README_AGENT manda)
1. Reclama el bead: `bd update {{ .issue.identifier }} --claim`
2. Branch desde develop: `docs/{{ .issue.identifier }}-<slug>` o `feat/...`
3. SOLO el alcance del bead. `make verify` en verde antes del PR.
4. PR a develop con el id del bead en el título. NUNCA toques main.
5. Al terminar: nota de handoff en el bead (`bd update`) con qué hiciste,
   qué falta y qué falló. NO cierres el bead — se cierra al fusionarse el PR.
