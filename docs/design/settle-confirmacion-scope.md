# `:settle` — Flujo de confirmación de pagos — Scope / diseño

> **Estado:** preguntas abiertas **RESUELTAS** por Andrea (2026-07-23). Implementa
> **ADR-0017**. Listo para construir tras su visto bueno formal del scope (design-first,
> constitution §2). Decisiones: flujo completo 5 rutas · pending caduca 30d · creación por
> lote · reject con motivo opcional · sugerencia avisa de pendientes · importe inmutable
> (cancel+recrea).

## 1. Idea en una frase
Un pago entre dos amigos es una **afirmación que las dos partes tienen que acordar**, no
un hecho que uno impone. `pending → confirmed | rejected`, y solo `confirmed` mueve saldos.

## 2. Máquina de estados

```
                 crea (from o to, actor∈{from,to})
        ∅  ───────────────────────────────────►  pending
                                                   │  │  │
             contraparte confirm ─────────────────►│  │  └──► cancelled  (creador, mientras pending)
                                                    │  │
             contraparte reject ────────────────────┘  └────► (queda registro; no mueve saldo)
                                                    ▼
                                                confirmed   ← única que cuenta para balances
```

- **Estados:** `pending`, `confirmed`, `rejected`, `cancelled`.
- **Transiciones y quién puede:**
  | Transición | Quién | Desde | Hasta |
  |---|---|---|---|
  | crear | `from` o `to` (actor = una de las dos) | ∅ | `pending` |
  | confirm | la **contraparte** (la parte ≠ actor creador) | `pending` | `confirmed` |
  | reject | la **contraparte** | `pending` | `rejected` |
  | cancel | el **creador** | `pending` | `cancelled` |
- **Terminales:** `confirmed`, `rejected`, `cancelled` (no re-transicionan).
- Idempotencia: crear = dedupe estructural ADR-0015 §5; confirm/reject/cancel idempotentes
  por `(actor, key)` ADR-0012 (repetir la misma transición = mismo resultado, no error).

## 3. Contrato HTTP (propuesta)

Todo bajo el grupo autenticado (JWT → `ctx.actor`). El `actor` **siempre** sale del JWT.

| Método · Ruta | Quién | Efecto | Respuestas |
|---|---|---|---|
| `POST /trips/:tripId/settlements` | miembro, actor∈{from,to} de cada item | crea **N** `pending` (lote) | 201 `{created:[{id,status:"pending"}…]}` · items en dedupe → `status:"duplicate"` · 403 no-miembro · 422 por item (`actor_not_party`/`invalid_amount`/`trip_closed`/`payee_not_member`) |
| `POST /trips/:tripId/settlements/:id/confirm` | la contraparte | `pending→confirmed` | 200 `{status:"confirmed"}` · 403 no-contraparte · 409 estado no-pending |
| `POST /trips/:tripId/settlements/:id/reject` | la contraparte | `pending→rejected` (con `reason?`) | 200 · 403 · 409 |
| `POST /trips/:tripId/settlements/:id/cancel` | el creador | `pending→cancelled` | 200 · 403 · 409 |
| `GET /trips/:tripId/settlements?status=pending` | cualquier miembro | lista | 200 `{settlements:[…]}` |

Body de creación (**lote**): `{settlements:[{settlementId, from, to, transferIndex,
amountMinor}, …]}`. El servidor **valida por item** que `actor ∈ {from, to}` (no lo deriva
a ciegas: tanto pagador como cobrador pueden registrar) y que `from`/`to` son miembros del
viaje. Un item inválido no tumba el lote: se responde su error en su posición.
Body de `reject`: `{reason?: string}` (opcional). Cada item del lote es un `pending`
independiente; **la confirmación es 1-a-1**, no por lote.

## 4. Saldos (encaja con bead `xsx`)
El motor de saldos resta **solo** los settlements `confirmed`. `pending`/`rejected`/
`cancelled` son invisibles para `balances()` y para la sugerencia. Así, `GET suggestion`
sigue siendo honesto: no descuenta pagos no acordados.

## 5. Notificación (encaja con bead `8hn` y el outbox)
Al crear un `pending`, encolar en el outbox una notificación a la **contraparte** ("X dice
que le pagaste / que le pagaste, confirma"). Al confirm/reject, notificar al creador. El
gate G4 de `8hn` (concurrencia + 1 outbox + 1 notificación) se cierra **aquí**, con DB real.

## 6. Modelo / esquema (impacto)
- `Settlement` gana `status`, `createdBy` (actor creador → define la contraparte),
  `expiresAt` (created_at + 30d), y `resolvedBy`/`resolvedAt`/`rejectReason?` (al resolver).
- Tabla `settlements`: añadir `status text not null default 'pending'`, `created_by text
  not null`, `expires_at timestamptz not null`, `resolved_by text`, `resolved_at
  timestamptz`, `reject_reason text`. La UNIQUE estructural de ADR-0015 §5 se mantiene
  sobre la creación.
- Migración nueva (**0002**) — no editar 0001 (append-only).
- **Caducidad:** job/cron que hace `pending→cancelled` donde `expires_at < now()` (encaja
  con la infra de cron/pinger; crear bead).

## 7. Preguntas abiertas (necesitan decisión de Andrea)

1. ✅ **RESUELTA (Andrea, 2026-07-23): la sugerencia AVISA de los pendientes.** Confirmado
   mueve saldo; un `pending` NO mueve saldo pero la sugerencia debe **señalar** que existe
   un pago pendiente entre ese par (para no empujar a pagar dos veces). Impacto: `GET
   suggestion` devuelve, junto a cada transferencia sugerida, si hay un `pending` que la
   cubre (p.ej. `"pending": true` o un bloque `pendingSettlements`). El saldo se calcula
   solo con `confirmed`; el aviso es informativo.
2. ✅ **RESUELTA: `reject` con motivo OPCIONAL.** Se puede rechazar en seco, pero el body
   admite un texto libre (`reason`) que viaja en la notificación al creador ("no recibí eso").
3. ✅ **RESUELTA: un `pending` CADUCA a los 30 días** sin respuesta → auto-`cancelled`.
   Necesita un job/cron que barra pendientes vencidos (encaja con la infra de cron/pinger
   ya existente; ver bead a crear). `expires_at = created_at + 30d` en el modelo.
4. ✅ **RESUELTA (default): NO se edita el importe de un `pending`.** Para cambiarlo, el
   creador **cancela y recrea**. Mantiene la afirmación inmutable una vez emitida.
5. ✅ **RESUELTA: confirmación por LOTE.** El `POST /settlements` acepta **varias**
   transferencias en una llamada (útil justo tras usar la sugerencia). Cada una nace como
   un `pending` independiente con su `transferIndex`; **la confirmación sigue siendo 1-a-1**
   (cada contraparte confirma/rechaza la suya). El lote es una comodidad de creación, no
   una unidad atómica de confirmación.
6. ✅ **RESUELTA: flujo COMPLETO, las 5 rutas** (crear-lote + confirm + reject + cancel +
   list) en este ciclo. Sin MVP recortado.

## 8. Plan de implementación (una vez aprobado)
Slices TDD, en este orden, cada uno con su ciclo rojo→verde + review de otro modelo:
1. Modelo (`status`/`createdBy`/`expiresAt`/`resolved*`/`rejectReason`) + migración **0002**.
2. Máquina de estados en el caso de uso (crear-lote / confirm / reject-con-motivo / cancel)
   + repo en-memoria. Reglas de autorización: actor∈{from,to} al crear; contraparte al
   confirm/reject; creador al cancel.
3. Adaptador Postgres (con test de **integración real** — cierra la parte DB de `8hn`).
4. Los **5 endpoints** HTTP + tests (crear-lote con validación por item, confirm/reject/
   cancel, list). Actor siempre del JWT.
5. Outbox/notificación (crear→contraparte; resolver→creador) + gate G4 completo (cierra `8hn`).
6. Job de **caducidad** 30d (`pending→cancelled`) + bead de cron.
7. Integración balances↔settlements **confirmed** + aviso de `pending` en `GET suggestion`
   (cierra `xsx`).
