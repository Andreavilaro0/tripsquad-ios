# README_AGENT — Reglas para agentes de la Fábrica TripSquad

**Borrador v0 (F0-core).** Todo agente que trabaje en este repo obedece estas reglas.
Fuente de autoridad: `constitution.md` > este archivo > preferencias del agente.
Design doc del sistema: `~/.gstack/projects/TripSquad-iOS/andreaavila-main-design-20260711-fabrica-multiagente.md` (APPROVED 2026-07-11).

## El principio

**Todo trabajo nace y muere en un bead.** Sin bead → el trabajo no existió.
Cerrar un bead exige evidencia enlazada: commit, PR, review o documento.

## Flujo de trabajo

1. `bd ready` → tomar un bead disponible → `bd update <id> --claim`.
2. Crear branch desde `develop`: `feat/<id>-<slug>` o `docs/<id>-<slug>`.
3. Trabajar SOLO el alcance del bead. Alcance nuevo = bead nuevo, no scope creep.
4. `make verify` en verde antes de abrir PR.
5. PR a `develop` con: qué, por qué, evidencia, y el id del bead en el título.
6. Review de modelos (Codex + MiniMax) contra `docs/agents/review-checklist.md`.
7. La etiqueta `ready-to-merge` la aplica el pipeline cuando los checks están verdes — **nunca el agente que escribió el código**.
8. **Andrea fusiona** (fase actual: autonomía ganada — ver design doc).
9. `bd close <id> --reason "<evidencia>"`.

## Límites duros

- **Tamaño de PR:** ≤400 líneas de diff neto. Más grande = partir en beads.
- **main es intocable.** Solo Andrea fusiona a main. Sin excepciones.
- **Prohibido rediseñar arquitectura sin ADR.** Cambios de arquitectura requieren
  ADR nuevo en `docs/decisions/` aprobado por Andrea ANTES de escribir código.
- **Ningún API sin doc real vía Context7** (constitution, anti-alucinación).
- **Ningún secreto en el repo.** gitleaks vigila; plantar un secreto = PR rechazado.
- **Presupuesto:** si tu modelo es de pago y el presupuesto mensual está agotado,
  el bead pasa a `blocked` con causa. Nunca degradación silenciosa.

## Definition of Done

Un bead está "done" cuando:
1. El cambio está fusionado en `develop` (por Andrea, o por pipeline en F2b).
2. `make verify` pasó en el commit fusionado.
3. Ambos revisores aprobaron (cualquier rechazo bloquea; el conflicto lo resuelve Andrea).
4. El bead está cerrado con evidencia enlazada.

## Estados de fallo del bead

| Situación | Acción |
|---|---|
| Agente muere a mitad de trabajo | bead → `blocked` con diagnóstico; branch se conserva; máx. 1 reintento por noche |
| API caída / rate limit | backoff con techo; bead → `blocked` con causa; se reporta en el aviso matinal |
| Review rechazada 2 rondas | bead → `blocked`; escala a Andrea con ambos reviews |
| Presupuesto agotado | bead → `blocked` (regla de presupuesto) |
| Branch huérfana >7 días | se borra tras volcar su diff como comentario en el bead |

## Ciclo limpio (gate de autonomía)

Un ciclo es "limpio" si: PR fusionado sin que Andrea pidiera cambios de código;
ambos revisores aprobaron en ≤2 rondas; evidencia completa en el bead.
**3 ciclos limpios + suite de contrato verde (F3) desbloquean el auto-merge nocturno a develop.**
