# ADR-0028 — Clave de idempotencia con `deviceId`: la fórmula de ADR-0012 §6 colisiona entre dispositivos del mismo usuario

- **Fecha:** 2026-07-28
- **Estado:** accepted
- **Dueña:** Andrea
- **Origen:** bead `00i`, hallazgo P0 de la voz externa **Gemini** sobre el contrato
  de `POST /sync/upload` (`docs/backend/contrato-sync-upload.md` §1)
- **Enmienda a:** ADR-0012 §6 (derivación de la `Idempotency-Key` desde el `CrudEntry`)
- **Supersede el punto concreto:** la fórmula `sha256(op_id ‖ table ‖ row_id)` de
  ADR-0012 §6. El resto de ADR-0012 (§1–§5, y del §6 el carácter **determinista** de
  la clave y el requisito de endpoint síncrono) **sigue vigente**.

> Los ADR anteriores **no se editan** (regla 4 de la constitution: append-only).
> Este ADR enmienda ADR-0012 §6 por escrito. Donde este documento y ADR-0012
> discrepan **en la fórmula de la clave**, manda este.

## Contexto

ADR-0012 §6 fijó cómo la cola de PowerSync deriva la `Idempotency-Key` de cada
operación:

> *"La `Idempotency-Key` se deriva de forma DETERMINISTA del `CrudEntry`
> (`sha256(op_id + table + row_id)`), nunca aleatoria por intento."*

El **determinismo** es correcto y no se toca: si la app crashea y reintenta, debe
generar **la misma** clave, o el duplicado está garantizado. El problema está en los
**ingredientes** de esa fórmula.

**El bug (P0, cazado por la voz externa Gemini al escribir el contrato de
`/sync/upload`):** el `op_id` de la fórmula es el `CrudEntry.clientId` de PowerSync —
la **secuencia de la operación**, un entero **LOCAL por dispositivo** que empieza en
1 en cada instalación. No es un identificador global.

En consecuencia, **dos dispositivos del mismo usuario** (el iPhone y el iPad de Marta)
que editan **la misma fila** generan cada uno su propia secuencia local y, con enorme
probabilidad, **el mismo `op_id`** (p. ej. `5`) para operaciones **distintas**. La
fórmula `sha256(op_id ‖ table ‖ row_id)` produce entonces **la misma clave** para dos
ediciones diferentes:

```
  iPhone de Marta:  op_id=5  table=expenses  row_id=9f3c…  → sha256("5|expenses|9f3c…")
  iPad de Marta:    op_id=5  table=expenses  row_id=9f3c…  → sha256("5|expenses|9f3c…")
                                                             ↑ MISMA clave
```

El servidor, al ver la segunda con una clave ya congelada (ADR-0012 §2), la trata
como **replay** de la primera y devuelve la respuesta vieja: **la segunda edición se
pierde en silencio**. Es exactamente el fallo que toda la maquinaria de idempotencia
existe para impedir, girado del revés — aquí la idempotencia *causa* la pérdida de un
dato legítimo en vez de evitar un duplicado.

El `UNIQUE (user_id, idempotency_key)` de ADR-0012 §2 **no salva** este caso: como
las dos operaciones comparten `user_id` (es la misma persona) y comparten la clave
derivada, colisionan dentro de la misma fila de `idempotency_keys`. La colisión es
**intra-usuario, entre dispositivos** — el punto ciego de una clave que no distingue
el dispositivo de origen.

## Decisión

**La `Idempotency-Key` incluye el `deviceId` como primer ingrediente:**

```
  idempotencyKey = sha256( deviceId ‖ crudId ‖ table ‖ rowId )
```

donde:

- **`deviceId`** — UUID que la app genera **una sola vez por instalación** y guarda en
  local. **NO** es un campo de `CrudEntry` (`CrudEntry` expone `id`, `clientId`,
  `transactionId`; no un identificador de dispositivo): lo aporta la app. Es el
  ingrediente que faltaba y el que rompe la colisión.
- **`crudId`** — es el `op_id` de la fórmula vieja, nombrado con precisión:
  `CrudEntry.clientId`, la **secuencia local** de la operación. Local por dispositivo,
  como antes.
- **`table` ‖ `rowId`** — sin cambios respecto a ADR-0012 §6.

Con el `deviceId` dentro del hash, las dos ediciones de Marta desde dos dispositivos
producen **claves distintas** → el servidor las procesa como **dos operaciones
legítimas** (y el árbitro de conflicto de ADR-0013 §2 / ADR-0015 §2 decide si la
segunda pisa o entra en `conflict`), en vez de descartar una como replay.

**Propiedades que se conservan (no se re-litigan):**

- **Determinismo por operación:** misma op → misma clave, siempre. El `deviceId` es
  estable por instalación y el `crudId` es determinista; reintentar tras un crash
  **no** regenera la clave. Reautenticar tampoco (ADR-0012 §5, contrato §4).
- **`UNIQUE (user_id, idempotency_key)`** (ADR-0012 §2) sigue siendo el candado del
  servidor: ahora las claves de dos dispositivos del mismo usuario **ya no chocan**, y
  el candado sigue impidiendo que **otro** usuario secuestre una clave ajena.
- **Dedupe estructural** (ADR-0012 §2, capa 2: PK de cliente + `ON CONFLICT DO
  NOTHING`) intacto como red final contra duplicados reales de *creates*.

## Ya está implementado — este ADR solo lo formaliza

La decisión **ya se tomó y se implementó** al redactar el contrato de la cola. Este
ADR no introduce nada nuevo: **cierra el hueco formal**. La constitution (regla 4)
reserva el cambio de una decisión `accepted` a un **ADR nuevo**; un documento de
referencia (el contrato) no puede, por sí solo, enmendar un ADR. Por eso ADR-0012 §6
quedaba, hasta ahora, formalmente diciendo `sha256(op_id ‖ table ‖ row_id)` mientras
el contrato ya usaba la fórmula correcta. Este ADR reconcilia ambos.

**El contrato que ya la usa:** `docs/backend/contrato-sync-upload.md` §1 —
*"⭐ `idempotencyKey` incluye el `deviceId` (hallazgo P0 de la voz externa Gemini —
corrige la fórmula de ADR-0012 §6): `sha256(deviceId ‖ crudId ‖ table ‖ rowId)`"*—
con el ejemplo `"idempotencyKey": "sha256(device-uuid-A|5|expenses|9f3c…)"` y el
`deviceId` como campo de nivel de batch (`"deviceId": "device-uuid-A"`).

**Aclaración sobre ADR-0015:** ADR-0015 §5 ya listó "enmienda a ADR-0012 §6", pero
por otro motivo — la **tabla local de intención** para `:settle` que §6 daba por
supuesta. ADR-0015 **no corrigió la fórmula de la clave**. Esa corrección es la que
formaliza **este** ADR-0028, y no solapa con la de ADR-0015.

## Alternativas consideradas

- **Dejar `sha256(op_id ‖ table ‖ row_id)`** (la fórmula vieja) — pierde silenciosamente
  la segunda edición de cualquier usuario con dos dispositivos. Es el bug. Descartada.
- **Usar `CrudEntry.transactionId` en vez de añadir `deviceId`** — también es local por
  dispositivo (misma secuencia reiniciada por instalación), así que **no** rompe la
  colisión entre dispositivos. No resuelve el problema.
- **Clave aleatoria (UUID) por intento** — rompe el determinismo: un reintento tras
  crash generaría una clave nueva → duplicado garantizado. Prohibida ya por ADR-0012 §6.
- **Derivar el `deviceId` de un campo de `CrudEntry`** — imposible: `CrudEntry` no
  expone identidad de dispositivo. Debe aportarlo la app, guardado en local por
  instalación. Es exactamente lo que hace el contrato.

## Consecuencias

- **ADR-0012 §6** queda enmendado **solo en la fórmula**: la clave es
  `sha256(deviceId ‖ crudId ‖ table ‖ rowId)`. El resto de §6 (determinismo, endpoint
  síncrono) sigue vigente palabra por palabra.
- **La app debe generar y persistir un `deviceId`** (UUID) por instalación, y enviarlo
  en el batch de `/sync/upload` (contrato §1). Es estado local nuevo, mínimo.
- **El servidor no deriva ni valida el `deviceId` contra `CrudEntry`**: lo recibe del
  cliente y lo usa tal cual dentro del hash. No es un dato de confianza para
  autorización (eso lo da el JWT / `user_id`); solo desambigua la clave.
- **Sin coste de esquema:** `idempotency_keys` no cambia; solo cambia *cómo* se calcula
  el valor que entra en su columna `idempotency_key`.
- **El gate G1c del contrato** (reenviar un batch ya aplicado da los mismos
  `crudId → outcome`, con `accepted` degradado a `replayed`, sin duplicar) sigue
  siendo la barrera; conviene añadir un caso que cubra explícitamente **dos
  dispositivos del mismo usuario editando la misma fila → dos operaciones, no un
  replay**.

## Fuentes

- ADR-0012 §2/§5/§6 (tabla de idempotencia, reauth, derivación determinista de la clave).
- ADR-0015 §5 (enmienda de §6 por la tabla de intención de `:settle`; **no** por la fórmula).
- `docs/backend/contrato-sync-upload.md` §1 (la fórmula con `deviceId`, ya implementada).
- PowerSync, *CrudEntry* (`id`, `clientId`, `transactionId` — el `clientId` es la
  secuencia local): https://docs.powersync.com/handling-writes/writing-client-changes
