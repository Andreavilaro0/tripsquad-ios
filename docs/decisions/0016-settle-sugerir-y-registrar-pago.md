# ADR-0016 — `:settle` = sugerir (GET) + registrar pago (POST)

- **Fecha:** 2026-07-23
- **Estado:** accepted
- **Dueña:** Andrea
- **Decide:** Andrea (sesión cockpit multi-IA, 2026-07-23)
- **Cierra:** la decisión de producto que ADR-0015 §13 dejó **abierta** ("hay que
  decidir qué significa liquidar"). No supersede ADR-0015; lo completa.
- **Depende de:** ADR-0011 (motor de saldos), ADR-0012 (idempotencia), ADR-0015 §5
  (dedupe estructural de liquidaciones con `settlementId` + `transfer_index`).

## Contexto

ADR-0015 §13 (hallazgo de la voz externa MiniMax) señaló que `:settle` mezclaba
**tres conceptos** que el plan trataba como uno, y que el endpoint no se podía
codegenerar sin decidir cuál es:

| Concepto | ¿Muta dinero? | ¿Peligroso al reejecutar? |
|---|---|---|
| **(a) Sugerir** quién paga a quién | No | No — lectura pura |
| **(b) Cerrar una ronda** (marcar deudas saldadas en bloque) | Sí | Sí — outbox + notificaciones |
| **(c) Registrar un pago real** ("le hice un Bizum de 20 €") | Sí | Sí |

El motor de dominio ya calcula (a) — `liquidar(saldos) -> [Transferencia]` — y el
esquema ya tiene la tabla `settlements` con la PK determinista de ADR-0015 §5
(`uuidv5(settlementId, from||to||transferIndex)` + `unique(trip_id, settlement_id,
from_member, to_member, transfer_index)`). Faltaba la decisión de producto.

## Decisión

**`:settle` se parte en dos recursos, separando la lectura pura de la escritura
peligrosa:**

1. **`GET /trips/:tripId/settlement/suggestion`** — concepto (a). Calcula las
   transferencias que dejan los saldos a cero (`liquidar`). **No muta nada**, no
   requiere `Idempotency-Key` ni `If-Match`. Reejecutar es inocuo. Requiere
   membresía activa.

2. **`POST /trips/:tripId/settlements`** — concepto (c). Registra **un pago real que
   alguien ya hizo** (`from` pagó `amount` a `to`). Es idempotente por
   `settlementId` generado en cliente: la fila se identifica por
   `uuidv5(settlementId, from||to||transferIndex)` con `ON CONFLICT DO NOTHING`, así
   que reintentar el mismo pago **no lo duplica** (ADR-0015 §5). El `from` no lo
   decide el cliente a su antojo para terceros: se registra con el actor autenticado
   como quien afirma el pago (trazabilidad; ADR-0014 §5 — el cliente no elige
   identidad).

**El concepto (b) "cerrar ronda entera" queda fuera de este ADR.** No se implementa
hasta que el producto lo pida; si llega, será un ADR nuevo (es la variante más
peligrosa: muta muchas deudas de golpe y dispara notificaciones a todo el squad).

## Alternativas consideradas

- **Un solo `:settle` polisémico** — lo que ADR-0015 §13 descartó: imposible de
  codegenerar y mezcla una lectura segura con una escritura peligrosa bajo el mismo
  verbo. Rechazado.
- **Solo sugerir (GET), sin registrar** — más seguro pero deja la app a medias: no
  se puede saldar nada. Válido como fase intermedia, pero Andrea pidió también (c).
- **Incluir (b) cerrar ronda ya** — más potente pero más peligroso y con más
  diseño (batch atómico + outbox). Aplazado a cuando el producto lo necesite.

## Consecuencias

- Se desbloquea el último P0 de la Fase S: **bead 8hn** (test G4 — dos `POST
  /settlements` concurrentes con el mismo `settlementId` = una sola ejecución) ya es
  testeable, porque el endpoint existe y su idempotencia es la de ADR-0015 §5.
- El `GET .../suggestion` es una lectura pura: no pasa por la máquina de
  idempotencia ni por `/sync/upload` (no es una escritura de la cola offline).
- El `POST /settlements` **sí** es una escritura y, si se enruta por la cola
  offline, obedece la regla del camino (ADR-0012 §4, gate G1): conflicto/rechazo en
  200, transitorio en 5xx, nunca un 4xx que congele la cola.
- La tabla `settlements` y su índice único ya soportan esto sin cambios de esquema.
- Registrar un pago **no** borra deudas del ledger de gastos: es una entrada nueva
  (append-only, no repudio, ADR-0014 §5). El saldo se recalcula incluyendo los
  settlements; no se muta hacia atrás.
