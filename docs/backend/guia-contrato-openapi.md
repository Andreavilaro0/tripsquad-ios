# Guía de diseño del contrato OpenAPI — TripSquad

**Tipo:** reference (Diátaxis) · **Origen:** bead R1 (`TripSquad-iOS-lea`) ·
**Fuente ancla:** Azure REST API Guidelines (la guía viva de Microsoft; el
`Guidelines.md` clásico está deprecado) + Graph Guidelines como contraste.
**Autoridad:** subordinada a `constitution.md` y a los ADRs. Los beads R3/R4/R5
cerraron las secciones que antes estaban pendientes; ADR-0015 fija las
correcciones. **Ya no queda nada abierto en esta guía.**

El contrato OpenAPI es la **fuente única de verdad del contrato HTTP** (ADR-0008):
los clientes Swift y Kotlin se generan de él, jamás a mano.

> ⚠️ **Hay DOS contratos, no uno** (ADR-0015 §14). OpenAPI **no** cubre las sync
> rules de PowerSync, el esquema SQLite del cliente, los buckets ni las columnas
> locales. Ese es un **segundo artefacto versionado**, y la **paridad entre los dos**
> tiene su propio gate de CI (ADR-0013 §4). Decir "el contrato OpenAPI es la fuente
> única de verdad" a secas es falso y peligroso: invita a olvidar la mitad de la
> superficie.

Cada regla de esta guía existe para proteger dos cosas: **clientes viejos vivos
durante meses** (ciclo App Store) y **una cola offline que reintenta a ciegas**
(PowerSync).

## 0. ⭐ La regla que manda sobre todas las demás: el código depende del CAMINO

**Una respuesta 4xx del endpoint de upload bloquea la cola de PowerSync entera, y
para siempre** (ADR-0012 §4). Por eso el mismo error se señaliza con **códigos
distintos según por dónde llegue la petición**:

| Situación | Llamada **directa** de API | Escritura desde la **cola** |
|---|---|---|
| Precondición fallida (`If-Match`) | **412** | **200** + `write_conflicts` |
| Rate limit / sobrecarga | **429** + `retry-after` | **503** + `retry-after` |
| Rechazo permanente (viaje cerrado, expulsado, validación) | **4xx** de negocio | **200** + `write_rejections` |
| Key de idempotencia expirada | **412** | **200** + `write_rejections` |
| Key en vuelo (concurrencia) | **409** | **409** ← la única 4xx permitida |
| Transitorio (BD caída, timeout) | **5xx** | **5xx** |
| Reintento de algo ya ejecutado | **200** + `Idempotency-Result: replayed` | igual |

**Invariante (gate de CI, ADR-0015 §8 G1): ninguna respuesta del camino de la cola
es 4xx salvo 409.** Un test de contrato enumera todos los caminos de error y falla
si alguno lo viola.

**Por qué el 409 sí y el resto no:** el 409 significa "reinténtalo luego" y el SDK
lo reintenta — que es lo que queremos cuando otra petición tiene la key en vuelo.
Un **412 de conflicto** con 409 sería un **bucle infinito** (el cliente reintentaría
con el mismo ETag rancio, eternamente), así que tampoco vale.

## 1. URLs y naming

- Forma: `https://api.tripsquad.app/{colección}/{id}` — colecciones en
  **plural**: `/trips/{tripId}/expenses`, `/trips/{tripId}/messages`,
  `/trips/{tripId}/polls`.
- Path segments en **kebab-case**; query params y campos JSON en **camelCase**;
  headers en kebab-case. Paths, query params, campos JSON e IDs son
  case-sensitive; los **nombres de header NO** — se comparan case-insensitive
  (RFC 9110 §5.1: URLSession, proxies y HTTP/2 pueden minusculizarlos, p. ej.
  `idempotency-key`).
- Los IDs son **strings opacos** generados en cliente (UUID): el servidor los
  almacena y compara case-sensitive, nunca los interpreta.
- Acciones no-CRUD: `POST /trips/{id}:action` — ej. `:settle` (liquidar),
  `:close` (cerrar votación), `:leave` (salir del viaje). Siempre POST; nunca
  verbos inventados en el path.

## 2. Versionado

- Query param **obligatorio** en toda operación: `api-version=YYYY-MM-DD`.
- Sin él → `400` con código `MissingApiVersion`; versión no soportada → `400`
  con `UnsupportedApiVersion` listando las válidas.
- **Breaking changes prohibidos dentro de una versión.** Añadir un campo
  requerido después de v1 ES breaking (solo se permite en v1).
- Por qué en query y no en path: un cliente antiguo instalado sigue funcionando
  meses; la fecha en query deja evolucionar el backend sin duplicar rutas.

## 3. Errores

Toda respuesta de error usa el objeto estándar (forma Azure, header renombrado):

```json
{ "error": { "code": "ExpenseAlreadySettled", "message": "…",
             "target": "expenseId", "details": [] } }
```

- Header `x-error-code` espejo de `error.code`.
- **Los `code` top-level son parte del contrato**: enumerados en el OpenAPI,
  estables, jamás se renombran. `message` es diagnóstico no-contractual (puede
  cambiar/traducirse — el cliente NUNCA lo parsea).
- **La cola offline NO clasifica por status 4xx** — no puede: un 4xx la congela
  (§0). Clasifica por el **cuerpo** de un `200`: `{"status": "rejected" | "conflict",
  "reason": …}`, más `5xx`/`503` para lo reintentable (respetando `retry-after`) y
  `409` para la key en vuelo. La política completa de escritura rechazada está en
  **ADR-0012 §4**; la de conflicto, en **ADR-0015 §2**.

## 4. Colecciones: paginación, filtrado, orden

- Respuesta = objeto con array **`value`** + **`nextLink`** (URL absoluta,
  **omitida** en la última página — nunca `null`). Cada item lleva `id` y `etag`.
- `nextLink` es **opaco**: permite migrar a cursor/keyset pagination sin romper
  clientes generados. Prohibido `?page=N` en el contrato.
- Orden estable y consistente entre páginas; fechas en orden cronológico.
- Filtrado: **subconjunto tipado declarado en OpenAPI** (ej.
  `?paidBy=<id>&from=<date>`), NO la gramática `filter=` completa de Azure —
  un intérprete de expresiones es superficie de inyección y trabajo
  desproporcionado para 3–5 filtros reales.

## 5. Escrituras: idempotencia y reintentos

Regla dura de Azure: *"All HTTP methods are idempotent"* — el móvil con red mala
reintenta, y un gasto duplicado es confianza rota.

- `PUT`/`DELETE`: idempotentes por naturaleza. `PATCH` **no lo es** (RFC 5789
  §2 — depende del formato): en este contrato PATCH se restringe a
  **merge-patch con semántica set-only** (asignar valores, jamás
  add/increment/append) + `If-Match` obligatorio — así el reintento de un
  timeout es seguro.
- `DELETE` → `204 No Content` **incluso si el recurso ya no existe** (nunca
  `404`): un reintento de la cola no debe marcar como fallo lo ya completado.
- **`DELETE` de un recurso editable exige `If-Match`** (ADR-0013): borrar es la
  mutación *más* destructiva, no la menos. Sin precondición, un DELETE encolado
  hace cinco días **borraría un gasto que otro miembro editó mientras tanto**. Si
  el ETag no coincide, la usuaria decide — pero **el código depende del camino**
  (§0): **412** en llamada directa, **`200` + `write_conflicts`** si viene de la
  cola. Las dos propiedades conviven: idempotente ante reintentos (`204` si ya no
  está), pero **no ciego** ante ediciones concurrentes.
- **Toda `POST` que muta estado lleva `Idempotency-Key` obligatorio** — tanto
  las de creación como las **acciones** de §1 (`:settle`, `:close`, `:leave`).
  Una acción no es menos peligrosa que un create: si la respuesta de `:settle`
  se pierde y la cola reintenta, se re-ejecutarían la liquidación, el outbox y
  las notificaciones a todo el squad. El replay devuelve el resultado de la
  primera ejecución con `Idempotency-Result: replayed`, **sin volver a ejecutar
  los efectos**.
- `POST`-create → `201` + URL del recurso (`Idempotency-Key` es el estándar de
  facto Stripe/IETF; adoptamos el patrón Repeatability de Azure con ese nombre):
  - El cliente envía `Idempotency-Key: <uuid>` + la petición lleva el ID de
    entidad generado en cliente (doble red: key + unique constraint).
  - El servidor responde `Idempotency-Result: created | replayed` — la cola
    offline DEBE distinguir "creado" de "ya estaba".
  - **Ventana de deduplicación: 60 días** (ADR-0012 §3). No 24 h como Stripe: un
    móvil sin red 10 días de viaje subiría su cola y **crearía el gasto otra vez,
    semanas después**. `Idempotency-First-Sent` es **obligatorio**; fuera de
    ventana, el servidor **jamás re-ejecuta a ciegas**.
- **Decidido: POST + `Idempotency-Key`, no PUT-create** (ADR-0012). Se evaluó
  `PUT /trips/{id}/expenses/{expenseId}` (idempotente sin maquinaria extra, ya que
  los IDs los genera el cliente), pero **PUT no cubre las acciones** (`:settle`,
  `:close`, `:leave`), que son las que de verdad hay que deduplicar — un `:settle`
  reejecutado re-dispara el outbox y notifica a todo el squad. Un solo mecanismo
  para todas las escrituras mutantes es más simple que dos.
- **La `Idempotency-Key` de una escritura de la cola se deriva de forma
  DETERMINISTA** del `CrudEntry` (`sha256(op_id + table + row_id)`), **nunca
  aleatoria por intento**: una key nueva en cada reintento = duplicado garantizado
  (ADR-0012 §6). Reautenticarse **tampoco** las regenera.
- **`:settle` se dedupe como un gasto** (ADR-0015 §5): lleva un `settlementId`
  (UUIDv7) generado en cliente, y cada fila de liquidación tiene PK determinista
  `uuidv5(settlementId, from ‖ to)` + `ON CONFLICT (id) DO NOTHING`. **El dedupe
  estructural es la garantía; la key es higiene.**

## 6. Concurrencia: ETags y condicionales

- Toda operación que devuelve o modifica un recurso devuelve **`ETag`**.
- Updates con **`If-Match`** obligatorio en recursos editables (gastos,
  itinerario). Precondición fallida: **`412`** en llamada directa, **`200` +
  `write_conflicts`** si viene de la cola (§0 — un 412 ahí la congelaría).
- `GET` con `If-None-Match` → `304` (ahorra datos en móvil).
- **El árbitro del conflicto es el ETag, NO un reloj** (ADR-0013 §2). Los relojes
  de cliente mienten (NTP roto, hora cambiada a mano, cruzar husos — que es
  literalmente nuestro caso de uso). El `server-receive-time` da el **orden
  canónico**; el HLC del cliente se guarda como metadato pero **no decide nunca**.
- **Cuándo se exige `If-Match`, exactamente** (ADR-0015 §12 — los creates no tienen
  ETag y esto se pasaba por alto):

  | Operación | `If-Match` | Protección |
  |---|---|---|
  | **Create** (fila nacida en local, nunca sincronizada) | **No** | PK de cliente + `ON CONFLICT DO NOTHING` |
  | **Update/Delete** de fila ya sincronizada | **Sí, obligatorio** | ETag que el cliente conocía → conflicto si no cuadra |
  | **Update/Delete** de fila local aún no confirmada | **No** | Se colapsan las operaciones **en local** antes de subirlas. Nunca viaja un `If-Match` inventado |

- **Todos los miembros pueden editar cualquier gasto** (ADR-0015 §15) — no hay roles
  ni candados. Pero *editar no es pisar*: el `If-Match` sigue siendo obligatorio, y
  toda edición queda registrada campo a campo en `expense_revisions` (append-only).

## 7. Operaciones largas (LRO)

> ⚠️ **`:settle` NO es un LRO** (ADR-0015 §7). Esta guía lo modelaba como operación
> larga; era un error por dos motivos. **(1)** Choca con ADR-0012 §6: el endpoint de
> escritura debe ser **síncrono respecto a la BD** ("nada de encolar para procesar
> luego") o se rompe la consistencia de checkpoints de PowerSync — un `202` hacia la
> cola es incompatible con lo que la cola necesita. **(2)** El umbral no se alcanza:
> liquidar N ≤ 12 miembros son **microsegundos**. Lo lento son las notificaciones, y
> esas ya salen por el **outbox**, sin que la respuesta las espere.
>
> **`:settle` responde síncrono.** El LRO se conserva **solo para el procesado de
> fotos**, que nunca viaja por la cola de escrituras.

- Umbral: si el p99 supera **1 segundo**, se modela como LRO. Hoy aplica **solo al
  procesado de fotos**.
- `202 Accepted` + header `operation-location` (URL absoluta del monitor).
- `GET <operation-location>` → `{ "id", "status":
  "NotStarted|Running|Succeeded|Failed|Canceled", "error", "result" }`.
- `retry-after` (segundos) en toda respuesta no terminal; el monitor se
  retiene ≥24 h — la app puede cerrarse y reabrirse sin perder el hilo.

## 8. Fechas, horas y duraciones

**Instantes vs fechas civiles — son dos tipos distintos, y confundirlos corrompe
la app.** Un viaje del 12 al 17 de junio no es un instante: si `startDate` viaja
como `date-time` UTC, un usuario en México (UTC−6) puede ver el día anterior, y
la duración del viaje y la agrupación por días del itinerario salen mal.

- **Instantes** (creación de un gasto, envío de un mensaje, auditoría):
  **RFC 3339 UTC** — `YYYY-MM-DDTHH:mm:ss.sssZ`, máximo 3 decimales
  (`format: date-time`; mapea a `Foundation.Date`). Con autoridad de
  **servidor** (premisa F3).
- **Fechas civiles** (`startDate`/`endDate` del viaje, el día de una actividad
  del itinerario): **`format: date`** — `YYYY-MM-DD`, sin hora ni zona. En
  Swift **no** se decodifican a `Date`: se modelan como fecha de calendario
  (`DateComponents`/tipo propio) y jamás se convierten a instante.
- Regla para decidir: si el valor del campo cambia al cruzar un huso horario,
  es una fecha civil.
- Headers: RFC 7231 IMF-fixdate.
- Duraciones: unidad en el nombre del campo (`durationInMinutes: int`), no
  ISO-8601 durations.
- Sufijos de campo: `…Date` / `…Time` / `…DateTime` según el tipo.

## 9. JSON: las reglas que protegen el decoder Swift

- **`null` no se envía en respuestas: el campo se omite** (mapea limpio a
  `Optional` en Swift). En PATCH (`application/merge-patch+json`), `null`
  significa BORRAR el campo — semántica distinta y deliberada.
- **Enums extensibles siempre** (`modelAsString`): todo enum del contrato
  (`expenseCategory`, `pollStatus`, `messageType`…) se genera con caso
  `unknown`/raw fallback. Un enum cerrado + un valor nuevo del servidor =
  **crash del decoder en apps ya publicadas**.
- Enteros dentro de ±(2^53−1).
- **Dinero: jamás JSON number** (decodifica a `Double`). En el contrato viaja
  como **string decimal** + `currencyCode`.

  **El dinero, de punta a punta** (ADR-0011 §2 + ADR-0015 §4 — fuente única; si
  otro documento dice otra cosa, manda esta tabla):

  | Capa | Tipo | Por qué |
  |---|---|---|
  | Contrato OpenAPI | **string decimal** + `currencyCode` | Un JSON number decodifica a `Double` |
  | Frontera (Data) | `Decimal(string:)` → `Int64` | **Nunca** `Decimal` desde literal `Double`: reintroduce el error binario |
  | Núcleo del dominio | **`Int64` de céntimos** | *Money pattern* (Fowler/Stripe). Exacto **por diseño** |
  | **Postgres** | **`bigint`** ← *antes decía `numeric`* | `int8 → integer` es exacto (ambos int64 con signo) |
  | SQLite del cliente | **`integer`** | Mapeo directo, sin conversión |

  🚫 **PROHIBIDO declarar una columna de dinero como `.real`** en el `Schema` del
  cliente PowerSync. Es la **única** puerta por la que el `Double` puede entrar: el
  esquema del cliente solo admite `text`/`integer`/`real` y PowerSync **castea en
  silencio** — *"Nothing in PowerSync will fail hard"*. Sin error, sin warning, sin
  log; y reaparece meses después como céntimos descuadrados. Lo vigila un gate de CI
  (ADR-0015 §8, G3).

  🚫 **`Double` prohibido en todo el camino del dinero.** `0.1 + 0.2 ≠ 0.3` en
  binario: acumular saldos con `Double` rompe la invariante de suma cero.
- Mutabilidad declarada por campo: create / update / read (el codegen genera
  los DTOs correctos por operación).

## 10. Tipos polimórficos

- Discriminador **`kind`** (enum extensible) + `oneOf` en OpenAPI — genera
  enums con valores asociados en Swift.
- Aplica a: eventos de itinerario (vuelo/hotel/actividad) y mensajes de chat
  (texto/foto/gasto).
- `kind` es inmutable en updates; nada de arrays de polimórficos en recursos
  actualizables.

## 11. Headers estándar

| Header | Dirección | Regla |
|---|---|---|
| `authorization: Bearer <jwt>` | → | Obligatorio salvo `/health` |
| `Idempotency-Key` | → | Obligatorio en **toda POST mutante** — creates Y acciones `:settle`/`:close`/`:leave` (§5) |
| `x-client-request-id` | → | Opcional; el servidor lo devuelve tal cual |
| `x-request-id` | ← | Siempre — id opaco único (soporte: "mándame el id del error") |
| `x-error-code` | ← | En errores, espejo de `error.code` |
| `Idempotency-First-Sent` | → | **Obligatorio** con `Idempotency-Key` (§5) — sin él no hay ventana de 60 días |
| `ETag` / `last-modified` | ← | En recursos (§6) |
| `Idempotency-Result` | ← | `created` \| `replayed` (§5) |
| `retry-after` | ← | En `503` (cola) y `429` (API directa); la cola lo RESPETA en su backoff |

- Tolerancia: un header desconocido **nunca** hace fallar la petición.

> ⚠️ **El `429` nunca viaja a la cola** (§0). `429` es un 4xx: enviárselo a la cola
> la **congela**, y precisamente a quien vuelve con 200 operaciones acumuladas — el
> usuario al que más le importa. Desde la cola, la sobrecarga se señaliza con
> **`503` + `retry-after`**.

## 12. Lo que NO adoptamos (y por qué)

- **OData completo** (`$select`, `$expand`, `$count`, `Edm.*`): ecosistema para
  clientes genéricos que componen queries arbitrarias; nuestros clientes son
  generados y conocidos.
- **Gramática completa de `filter`/`orderby`**: intérprete de expresiones =
  superficie de ataque; basta el subconjunto tipado (§4).
- **URLs multi-tenant/multi-región y convenciones ARM**: servicio único.
- **Gobernanza enterprise** (Breaking Change Reviewers, deprecación a 36
  meses, canal `-preview`): la política de deprecación la marca la adopción
  en App Store, no un SLA.
- **Nombres `Repeatability-*` y `x-ms-*`**: adoptamos los patrones con nombres
  propios (`Idempotency-Key`, `x-request-id`, `x-error-code`).

## 13. Checklist para PRs que tocan el contrato

- [ ] 🔴 **¿NINGUNA respuesta del camino de la cola es 4xx salvo 409?** (§0) — el conflicto va `200`+`write_conflicts`, el rate limit `503`, el rechazo `200`+`write_rejections`. **Un solo 4xx aquí congela la cola de esa persona para siempre.**
- [ ] 🔴 **¿Ninguna columna de dinero se declara `.real`** en el `Schema` del cliente? (§9) — PowerSync castea a `Double` **en silencio**.
- [ ] ¿Toda operación acepta `api-version` y está en el changelog del contrato?
- [ ] ¿Los errores nuevos añaden su `code` al enum contractual?
- [ ] ¿Las colecciones devuelven `value` + `nextLink` opaco?
- [ ] ¿**Toda** POST mutante (creates Y acciones `:settle`/`:close`/`:leave`) requiere `Idempotency-Key` + `Idempotency-First-Sent` y responde `Idempotency-Result`? ¿Los DELETE devuelven `204` siempre?
- [ ] ¿La `Idempotency-Key` de la cola se deriva **determinísticamente** del `CrudEntry` (nunca aleatoria por intento, nunca regenerada al reautenticar)?
- [ ] ¿Los recursos editables llevan `ETag`/`If-Match`, **incluidos los DELETE**? ¿Y los **creates NO** lo exigen (§6)?
- [ ] ¿Toda escritura mutante tiene **dedupe estructural** (PK de cliente + `ON CONFLICT DO NOTHING`), y no solo la tabla de claves? — la capa 2 es la garantía; la 1 es higiene.
- [ ] ¿Los enums son extensibles? ¿Ningún campo `null` en respuestas? ¿Ningún dinero como number, y `bigint` en Postgres?
- [ ] ¿Cada campo de fecha usa el tipo correcto — `format: date` para fechas civiles (viaje, día de itinerario) y `date-time` UTC solo para instantes? ¿Duraciones con unidad en el nombre?
- [ ] ¿Operaciones >1s p99 modeladas como LRO?
- [ ] ¿Ningún campo requerido añadido después de v1?

## Fuentes

- Azure REST API Guidelines (fuente principal):
  https://github.com/microsoft/api-guidelines/blob/vNext/azure/Guidelines.md
- Microsoft Graph REST API Guidelines (contraste, change tracking):
  https://github.com/microsoft/api-guidelines/blob/vNext/graph/GuidelinesGraph.md
- El `Guidelines.md` raíz del repo está deprecado y redirige a los dos anteriores.
- Idempotency-Key: convención Stripe / draft IETF `draft-ietf-httpapi-idempotency-key-header`.
