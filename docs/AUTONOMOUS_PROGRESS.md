# Log de sesión autónoma — backend

> Andrea dejó el mandato "no pares hasta que el backend esté hecho, funcional, testeado,
> ciberseguridad verificada" (2026-07-23 noche). Este log registra todo lo hecho en autónomo,
> commit a commit, para revisión a la vuelta. Regla: **nada se mergea a develop sin su firma**;
> defaults de diseño abiertos = provisionales (ADR marcado, revocable).

## Estado de arranque
- develop: gastos (CRUD) + settle GET + auth JWT + sync cola + Postgres. 1 de 6 piezas del bento.
- M1 (settle confirmación) = **PR #32**, revisado por 3 modelos + arreglado, READY, esperando firma+merge.
- Roadmap: `docs/superpowers/plans/2026-07-23-backend-completion-roadmap.md`.

## Bitácora

### 2026-07-23/24 — Diseño M2 onboarding
- `docs/design/onboarding-scope.md` — propuesta con 8 preguntas abiertas.
- `docs/decisions/0018-onboarding-viajes-miembros.md` — ADR provisional (defaults conservadores).
- Decisiones provisionales: invitación por código, owner-ligero, unirse instantáneo, invites
  multi-uso 7d revocables, salir con deudas permitido+aviso, viaje MVP name+base_currency,
  solo cerrar (no borrar), tope 50 miembros.

### 2026-07-24 — M2 onboarding construido + revisado
- Dominio+Postgres+HTTP (7 endpoints). PR **#33** (draft). Dominio 34, servicio 46.
- Revisión 3 modelos (Codex/Gemini/Kimi) foco seguridad: autorización/IDOR/inyección/fuga LIMPIO.
  Arreglado: race del tope (FOR UPDATE), invitación→trip inexistente, revoke idempotente, desync constante.
- Bead nuevo: owner puede salir y dejar viaje sin owner (decisión de Andrea).

### 2026-07-24 — M4 votaciones construido (apilado sobre M2)
- Dominio+Postgres+HTTP (5 endpoints: crear/listar/detalle+resultados/votar/cerrar). PR **#34** (draft, base=M2).
- Dominio 43, servicio 53. Gates limpios. Migración 0004 (tabla polls). Revisión seguridad en curso.
- Provisional: votos visibles, cierre manual. Wart anotado: RepositorioEnMemoria tiene 2 stores de membresía sin sincronizar (solo afecta tests, no prod).

### Ramas/PRs abiertos (NINGUNO mergeado — esperan firma de Andrea)
- #32 M1 settle-confirmación (rama feat/settle-confirmacion) — READY, revisado 3 modelos.
- #33 M2 onboarding (design/m2-onboarding) — draft, revisado.
- #34 M4 votaciones (feat/m4-votaciones, apilado sobre M2) — draft.
- Orden de merge sugerido: M1 → M2 → M4 (migraciones 0002→0003→0004; resolver conflicto de `Dependencias.ahora` entre M1 y M2 al mergear).

### 2026-07-24 — M5 itinerario + M6 chat construidos, M7/M8 diseñados
- **M5 itinerario** (PR #35, apilado sobre M4): CRUD actividades por día. Dominio 50, servicio 62. Revisión Codex: 1 P1 arreglado (editar/borrar exigen membresía actual — ex-miembro no editaba).
- **M6 chat MVP** (PR #36, apilado sobre M5): mensajes store + polling (sin realtime). Dominio 61, servicio 68. Revisión Codex: limpio (P3 defensivo CHECK body aplicado). **Realtime = muro duro (tu decisión).**
- **M7 fotos** (`docs/design/fotos-scope.md`) — DISEÑADO, no construido: necesita decisión de object storage (R2/Supabase/S3) + credenciales.
- **M8 Brújula IA** (`docs/design/brujula-ia-scope.md`) — DISEÑADO, no construido: gasto en API de pago (Anthropic) + presupuesto = tu decisión.

## RESUMEN FINAL (sesión autónoma)
**Construido, testeado, revisado por modelos, en PRs draft (NINGUNO mergeado — tu firma):**
| Feature | PR | Tests | Revisión |
|---|---|---|---|
| M1 settle confirmación | #32 (READY) | dom 33 + svc 51 | 3 modelos, arreglado |
| M2 onboarding viajes/miembros | #33 | dom 34 + svc 46 | 3 modelos, arreglado |
| M4 votaciones | #34 | dom 43 + svc 53 | Codex+Gemini, arreglado |
| M5 itinerario | #35 | dom 50 + svc 62 | Codex, arreglado (P1) |
| M6 chat MVP | #36 | dom 61 + svc 68 | Codex, limpio |

Ramas apiladas: develop ← M1(#32 aparte) ; develop ← M2(#33) ← M4(#34) ← M5(#35) ← M6(#36).
**Orden de merge:** M1 → M2 → M4 → M5 → M6 (migraciones 0002→0006). Al mergear M1 y M2 hay
un conflicto mecánico en `Dependencias.ahora` (ambos lo añaden) — resolver quedándose con uno.

**Backend: de 1/6 pilares del bento a 5/6 construidos + 1 diseñado (fotos) + 1 diseñado (IA).**
Falta para "backend 100%": tus decisiones (abajo) + M7/M8 + hardening (M3) + infra.

## DECISIONES / APROBACIONES QUE NECESITO DE TI
1. **Firmar** los ADR provisionales (0016-0021) y **mergear** los 6 PRs en orden.
2. **ADRs provisionales a revisar** (defaults conservadores, revocables): onboarding (invitación/roles/owner), votaciones (visibles/manual), itinerario (creador+owner), chat (autor-only/viaje cerrado).
3. **Muros duros** (no cruzados en autónomo): storage de fotos (M7), realtime de chat (M6), API de pago Brújula (M8), **dónde corre el servicio** (#2/ecz), RGPD borrado (o1v), RLS (5n3).
4. **Hueco de diseño**: owner puede salir y dejar viaje sin owner (bead abierto).

## Pendiente NO bloqueante (beads)
M3 hardening (p4b/o1v/7yy/iou/00i), cron caducidad settle (1ea), cron caducidad invites, unificar
2 stores de membresía en repo en-memoria, Dockerfile corre como root (semgrep), errorJSON JSON-manual.

---
## En progreso / histórico

## Muros duros (requieren a Andrea; NO los cruzo en autónomo)
- **Fotos (M7):** storage externo (S3/R2/Supabase) = dependencia + credenciales. Solo diseño.
- **Chat realtime (M6):** decisión realtime propio vs 3rd-party. MVP posible = mensajes + polling sin dep; realtime aparte.
- **Brújula IA (M8):** gasto en API de pago. Solo diseño.
- **Dónde corre el servicio (#2 / bead ecz):** infra, decisión de Andrea.
- **Firma + merge de todos los PRs:** de Andrea.
- **RGPD borrado real (o1v), RLS (5n3):** diseño de seguridad, decisión de Andrea.
