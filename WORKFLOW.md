---
# Fábrica TripSquad — workflow del despachador Sortie
# Fuente de verdad de tickets: Beads (bd). Este tracker `file` lee el export
# generado por scripts/beads-to-sortie.py — Sortie nunca escribe en él.
tracker:
  kind: file
  active_states:
    - open
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

# Los hooks corren por workspace/attempt, no por poll — el refresco del export
# beads→sortie lo hace before_run (y un cron externo cuando esté en el Pi).
hooks:
  before_run: |
    python3 scripts/beads-to-sortie.py
  after_run: |
    python3 scripts/beads-to-sortie.py
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
