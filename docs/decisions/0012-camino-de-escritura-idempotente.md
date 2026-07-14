# ADR-0012 — Camino de escritura idempotente y cola offline

- **Fecha:** 2026-07-14
- **Estado:** proposed
- **Dueña:** Andrea
- **Origen:** bead R4 (`TripSquad-iOS-3h7`), design doc Backend F3
- **Depende de:** ADR-0009 (Outbox + idempotencia), ADR-0011 (dinero en enteros)

## Contexto

El bug predicho por Gemini: **gasto duplicado por reintento**. Un móvil sin
cobertura reintenta a ciegas; si la deduplicación falla, el squad ve dos veces el
mismo gasto y los saldos mienten. Este ADR fija el camino de escritura completo:
claves de idempotencia, dedupe estructural, ventana de retención, qué pasa con
una escritura rechazada para siempre, y cómo se reautentica antes de vaciar la
cola.

## Decisión

### 1. Contrato: códigos del draft IETF

Se adopta `Idempotency-Key` con los códigos del **draft IETF**
(`draft-ietf-httpapi-idempotency-key-header`), más explícitos que los de Stripe:

| Código | Caso |
|---|---|
| **400** | Falta el header en una POST mutante |
| **409** | Petición **concurrente**: la original sigue en vuelo → reintentar luego |
| **422** | Key reusada con **payload distinto** |
| **412** | Key **fuera de la ventana** de retención (§3) → rechazo permanente. **Solo en llamadas directas de API, NUNCA en escrituras que vienen de la cola** (ver §4) |

Respuesta: `Idempotency-Result: created | replayed` (equivalente al
`Repeatability-Result` de OASIS). El servidor **publica su política de
expiración**, como exige el draft.

⚠️ **Los códigos 4xx de esta tabla valen para clientes que llaman a la API
directamente. Las escrituras que llegan desde la cola de PowerSync se rigen por
§4: un 4xx allí bloquearía la cola entera.** El único 4xx admitido en el camino de
la cola es el **409** (en vuelo), porque queremos que reintente.

### 2. Dos capas: la clave (HTTP) y el constraint (dominio)

**Capa 1 — tabla de idempotencia** (diseño de Brandur, ex-Stripe):
`UNIQUE (user_id, idempotency_key)`, `request_hash` (sha256 del cuerpo canónico →
detecta el 422), `locked_at` (petición en vuelo), `recovery_point` (máquina de
estados que permite reanudar tras un crash a mitad), y la respuesta congelada
(`response_code`, `response_body`) para el replay.

Carrera entre dos reintentos simultáneos:
`INSERT … ON CONFLICT (user_id, idempotency_key) DO UPDATE SET locked_at = now()
WHERE locked_at IS NULL`, en transacción `SERIALIZABLE`. El perdedor recibe
**409**. El lock lleva timeout (~30 s) para no bloquear eternamente si el proceso
muere.

**Capa 2 — dedupe estructural (la que de verdad mata el bug):**

```sql
ALTER TABLE expenses ADD PRIMARY KEY (id);            -- UUID generado en cliente
CREATE UNIQUE INDEX ON settlements (trip_id, from_member, to_member, round);
CREATE UNIQUE INDEX ON poll_votes  (poll_id, member_id);
CREATE UNIQUE INDEX ON trip_members (trip_id, member_id);
```

Con la PK generada en cliente, un `INSERT … ON CONFLICT (id) DO NOTHING` hace que
**el gasto duplicado sea físicamente imposible**, aunque toda la capa de
idempotencia falle. La capa 1 es higiene; **la capa 2 es la garantía**.

### 3. Ventana de retención: 60 días (y por qué no 24 h)

Stripe purga las claves a las **24 h**, y reusar una key purgada **genera una
petición nueva** — es decir, **re-ejecuta**. Ese es exactamente nuestro bug: un
móvil sin red 10 días en un viaje sube su cola y **crea el gasto por segunda vez,
semanas después**.

La spec **OASIS Repeatable Requests** (la que usa Azure) reconoce el caso
explícitamente: los dispositivos "occasionally-connected" pueden necesitar
"significant retention period (e.g. **50 days**)". Tres defensas apiladas:

1. **Retención de 60 días** (la tabla solo guarda hash + respuesta: es barato), con
   un *reaper* diario.
2. **`Idempotency-First-Sent` obligatorio** (equivalente al de OASIS): si
   `now() − first_sent > ventana`, el servidor devuelve **412** y **jamás
   re-ejecuta a ciegas**.
3. **Dedupe estructural** (§2) como red final.

### 4. Escritura rechazada para siempre: **nunca un 4xx a la cola**

Regla contraintuitiva y **crítica** de PowerSync: si el endpoint de upload
devuelve **4xx, la cola entera se bloquea** — y para siempre. Un solo gasto
rechazado congelaría todas las escrituras pendientes del usuario.

Por tanto:

- **Rechazo permanente** (viaje cerrado, te expulsaron, validación fallida):
  responder **200 OK** con `{"status":"rejected","reason":"trip_closed", …}` — la
  cola avanza — y **escribir una fila en `write_rejections`, que se sincroniza de
  vuelta al cliente** (dead-letter visible).
- El cliente **nunca borra el dato en silencio**: el gasto sigue en la SQLite
  local marcado como `rejected`, con UI honesta ("Este gasto no se pudo guardar:
  el viaje está cerrado") y tres acciones: **reintentar**, **copiar a otro viaje**
  o **descartar** — descartar es siempre un acto explícito de la usuaria.
- **Rechazo transitorio** (5xx, red, BD caída): responder **5xx** → el SDK
  reintenta solo con backoff.
- **409** (key en vuelo) es la única 4xx permitida, precisamente porque queremos
  que reintente.
- **Key expirada (`first-sent` fuera de ventana) en una escritura de la cola:** se
  trata como **rechazo permanente**, no como 412. Devolver un 412 crudo haría
  fallar `uploadData()` **antes** de `batch.complete()`, dejando la operación
  rancia a la cabeza de la cola FIFO: el SDK la reintentaría para siempre y
  **ninguna escritura offline posterior podría drenar**. Respuesta correcta:
  **200 OK** + `{"status":"rejected","reason":"idempotency_key_expired"}` + fila en
  `write_rejections`. El 412 queda reservado a las llamadas directas de API.
- Toda fila de `write_rejections` es una **señal de producto**, no un log: se
  monitoriza.

**Tabla de mapeo (el contrato que implementa la cola):**

| Situación | Respuesta al camino de la cola | Efecto |
|---|---|---|
| Transitorio (BD caída, timeout) | **5xx** | El SDK reintenta con backoff |
| Permanente (viaje cerrado, expulsado, validación) | **200** + `write_rejections` | La cola avanza; la usuaria ve el error |
| Reintento de algo ya ejecutado | **200** + `Idempotency-Result: replayed` | La cola avanza; sin duplicado |
| Key en vuelo (concurrencia) | **409** | La cola espera y reintenta |
| **Key expirada** | **200** + `write_rejections` (**no 412**) | La cola avanza; no se re-ejecuta a ciegas |

### 5. Reautenticación antes del flush

El JWT caduca (10 días sin red) y la cola tiene escrituras pendientes.

1. **Antes de cada flush**, el connector pide credenciales frescas
   (`fetchCredentials()`, que por contrato **nunca** devuelve valores cacheados).
   Si al JWT le quedan < 60 s, se usa el **refresh token** contra el servicio.
2. **Refresh OK** → se procesa la cola **con las Idempotency-Keys intactas**.
   ⚠️ **Reautenticar no puede regenerar las claves**: si al re-loguearse se
   generan keys nuevas, el duplicado está garantizado.
3. **Refresh caducado/revocado** → **no se vacía la cola ni se borra la base local**.
   Se marca la sesión como *needs re-auth* y se pide login ("Inicia sesión para
   subir 7 cambios pendientes"). Al volver **el mismo usuario**, el flush se reanuda
   con las claves originales.
4. **Si se loguea OTRO usuario** en el dispositivo: la cola del anterior **no se
   sube con las credenciales nuevas** (sería un fallo de autorización). Se conserva
   aislada por `user_id` o se ofrece exportar. **Nunca se descarta en silencio.**
5. El `UNIQUE (user_id, idempotency_key)` del servidor hace que un token nuevo del
   mismo usuario replaye correctamente, y que otro usuario **no pueda secuestrar**
   una key ajena.

### 6. Cola de PowerSync → nuestra API

- Se implementa `uploadData(database)`: se toma `getCrudBatch()` (ops PUT/PATCH/
  DELETE) y **se traducen a las llamadas POST de nuestro contrato de dominio**
  (`:settle`, `:close`, `:leave`…). `batch.complete()` solo cuando el servidor
  confirma. La doc de PowerSync da control total sobre la forma de la API.
- **La `Idempotency-Key` se deriva de forma DETERMINISTA del `CrudEntry`**
  (`sha256(op_id + table + row_id)`), **nunca aleatoria por intento**: si el app
  crashea y reintenta, debe generar **la misma key**. Una key aleatoria por intento
  = duplicado garantizado.
- El endpoint de escritura debe ser **síncrono respecto a la BD** (nada de encolar
  para procesar luego), o se rompe la consistencia de checkpoints de PowerSync.

## Alternativas consideradas

- **Ventana de 24 h como Stripe** — apropiada para un backend web con red
  permanente; en una app de viajes es el bug: el reintento tardío re-ejecuta.
- **Solo dedupe estructural, sin tabla de claves** — mata el duplicado, pero pierde
  el *replay* (el cliente no distingue "creado" de "ya estaba") y no protege las
  acciones que no son creates (`:settle`).
- **Devolver 4xx en rechazos permanentes** (lo natural en REST) — **bloquearía la
  cola de PowerSync entera**. Descartado por su doc.
- **Regenerar claves al reautenticar** (lo que haría un cliente ingenuo) —
  duplicado garantizado.

## Consecuencias

- La guía de contrato (R1) se amplía con los códigos 400/409/422/412 y el header
  `Idempotency-First-Sent`.
- El esquema nace con la tabla `idempotency_keys`, la tabla `write_rejections` y
  los unique indexes del dedupe estructural.
- La UI debe tener un estado "rechazado" para las escrituras offline: no es un
  detalle técnico, es una pantalla.
- Coste aceptado: una tabla más y un reaper diario.

## Fuentes

- Stripe, *Idempotent requests* (retención 24 h; 409 en concurrencia): https://docs.stripe.com/api/idempotent_requests
- Draft IETF, *Idempotency-Key header* (400/409/422): https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-idempotency-key-header
- Brandur, *Implementing Stripe-like idempotency keys in Postgres*: https://brandur.org/idempotency-keys
- OASIS, *Repeatable Requests v1.0* (retención larga para móviles, ~50 días; 412 al expirar): https://docs.oasis-open.org/odata/repeatable-requests/v1.0/cs01/repeatable-requests-v1.0-cs01.html
- Azure, *Repeatable requests*: https://learn.microsoft.com/en-us/rest/api/communication/repeatable-requests
- PowerSync, *Writing client changes* (un 4xx bloquea la cola): https://docs.powersync.com/handling-writes/writing-client-changes
- PowerSync, *Authentication setup* (`fetchCredentials` siempre fresco): https://docs.powersync.com/installation/authentication-setup
