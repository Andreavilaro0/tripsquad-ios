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

## Muros duros (requieren a Andrea; NO los cruzo en autónomo)
- **Fotos (M7):** storage externo (S3/R2/Supabase) = dependencia + credenciales. Solo diseño.
- **Chat realtime (M6):** decisión realtime propio vs 3rd-party. MVP posible = mensajes + polling sin dep; realtime aparte.
- **Brújula IA (M8):** gasto en API de pago. Solo diseño.
- **Dónde corre el servicio (#2 / bead ecz):** infra, decisión de Andrea.
- **Firma + merge de todos los PRs:** de Andrea.
- **RGPD borrado real (o1v), RLS (5n3):** diseño de seguridad, decisión de Andrea.
