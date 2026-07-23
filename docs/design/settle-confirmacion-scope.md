# `:settle` — Flujo de confirmación de pagos — Scope / diseño

> **Estado:** borrador para aprobación de Andrea (design-first, constitution §2).
> Implementa **ADR-0017**. No se codifica nada de esto hasta que Andrea firme + resuelva
> las **preguntas abiertas** del final.

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
| `POST /trips/:tripId/settlements` | miembro, actor∈{from,to} | crea `pending` | 201 `{id,status:"pending"}` · 200 si dedupe · 403 no-miembro · 422 `actor_not_party`/`invalid_amount`/`trip_closed`/`payee_not_member` |
| `POST /trips/:tripId/settlements/:id/confirm` | la contraparte | `pending→confirmed` | 200 `{status:"confirmed"}` · 403 no-contraparte · 409 estado no-pending |
| `POST /trips/:tripId/settlements/:id/reject` | la contraparte | `pending→rejected` | 200 · 403 · 409 |
| `POST /trips/:tripId/settlements/:id/cancel` | el creador | `pending→cancelled` | 200 · 403 · 409 |
| `GET /trips/:tripId/settlements?status=pending` | cualquier miembro | lista | 200 `{settlements:[…]}` |

Body de creación: `{settlementId, from, to, transferIndex, amountMinor}`. El servidor
**valida** que `actor ∈ {from, to}` (no lo deriva a ciegas, para permitir que tanto el
pagador como el cobrador registren). `from`, `to` deben ser miembros del viaje.

## 4. Saldos (encaja con bead `xsx`)
El motor de saldos resta **solo** los settlements `confirmed`. `pending`/`rejected`/
`cancelled` son invisibles para `balances()` y para la sugerencia. Así, `GET suggestion`
sigue siendo honesto: no descuenta pagos no acordados.

## 5. Notificación (encaja con bead `8hn` y el outbox)
Al crear un `pending`, encolar en el outbox una notificación a la **contraparte** ("X dice
que le pagaste / que le pagaste, confirma"). Al confirm/reject, notificar al creador. El
gate G4 de `8hn` (concurrencia + 1 outbox + 1 notificación) se cierra **aquí**, con DB real.

## 6. Modelo / esquema (impacto)
- `Settlement` gana `status` y `createdBy` (actor creador, para saber quién es la
  contraparte). Posible `resolvedBy`/`resolvedAt`.
- Tabla `settlements`: añadir `status text not null default 'pending'` y `created_by text
  not null`. La UNIQUE estructural de ADR-0015 §5 se mantiene sobre la creación.
- Migración nueva (0002) — no editar 0001 (append-only).

## 7. Preguntas abiertas (necesitan decisión de Andrea)

1. **¿Quién ve la deuda saldada, cuándo?** Confirmado ✅ mueve saldo. ¿La sugerencia debe
   *avisar* de que hay un `pending` sin resolver, o ignorarlo del todo hasta confirmarse?
2. **¿`reject` necesita motivo?** (p.ej. "yo no recibí eso") ¿o es un no seco?
3. **¿Caduca un `pending`?** (p.ej. auto-cancel a los N días sin respuesta) ¿o vive para
   siempre hasta que alguien lo resuelva?
4. **¿Puede el creador editar el importe de un `pending`?** ¿o solo cancelar y recrear?
5. **¿Confirmación por lote?** (liquidar varias deudas de golpe tras usar la sugerencia)
   ¿o un settlement por transferencia? (afecta al `transferIndex`.)
6. **MVP vs completo:** ¿construimos ya las 5 rutas, o un MVP (crear + confirm + list) y
   dejamos reject/cancel/caducidad para después?

## 8. Plan de implementación (una vez aprobado)
Slices TDD, en este orden, cada uno con su ciclo rojo→verde + review de otro modelo:
1. Modelo `status`/`createdBy` + migración 0002.
2. Máquina de estados en el caso de uso (crear/confirm/reject/cancel) + repo en-memoria.
3. Adaptador Postgres (con test de integración real — cierra la parte DB de `8hn`).
4. Endpoints HTTP + tests.
5. Outbox/notificación + gate G4 completo (cierra `8hn`).
6. Integración balances↔settlements confirmados (cierra `xsx`).
