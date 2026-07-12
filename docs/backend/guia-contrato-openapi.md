# Guía de diseño del contrato OpenAPI — TripSquad

**Tipo:** reference (Diátaxis) · **Origen:** bead R1 (`TripSquad-iOS-lea`) ·
**Fuente ancla:** Azure REST API Guidelines (la guía viva de Microsoft; el
`Guidelines.md` clásico está deprecado) + Graph Guidelines como contraste.
**Autoridad:** subordinada a `constitution.md` y a los ADRs. Los beads R3/R4/R5
refinan las secciones marcadas con ⏳.

El contrato OpenAPI es la **fuente única de verdad** (ADR-0008): los clientes
Swift y Kotlin se generan de él, jamás a mano. Cada regla de esta guía existe
para proteger dos cosas: **clientes viejos vivos durante meses** (ciclo App
Store) y **una cola offline que reintenta a ciegas** (PowerSync).

## 1. URLs y naming

- Forma: `https://api.tripsquad.app/{colección}/{id}` — colecciones en
  **plural**: `/trips/{tripId}/expenses`, `/trips/{tripId}/messages`,
  `/trips/{tripId}/polls`.
- Path segments en **kebab-case**; query params y campos JSON en **camelCase**;
  headers en kebab-case. Todo case-sensitive.
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
- La cola offline clasifica por `code` + status: reintentable (`429`, `5xx`,
  respetando `retry-after`) / permanente (`4xx` de negocio) / conflicto (`409`,
  `412`). ⏳ R4 define la política exacta de escritura rechazada.

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

- `PUT`/`PATCH`/`DELETE`: idempotentes por naturaleza.
- `DELETE` → `204 No Content` **incluso si el recurso ya no existe** (nunca
  `404`): un reintento de la cola no debe marcar como fallo lo ya completado.
- `POST`-create → `201` + URL del recurso, con **`Idempotency-Key`
  obligatorio** (estándar de facto Stripe/IETF; adoptamos el patrón
  Repeatability de Azure con este nombre):
  - El cliente envía `Idempotency-Key: <uuid>` + la petición lleva el ID de
    entidad generado en cliente (doble red: key + unique constraint).
  - El servidor responde `Idempotency-Result: created | replayed` — la cola
    offline DEBE distinguir "creado" de "ya estaba".
  - Ventana de deduplicación finita (mínimo 5 min; ⏳ R4 fija el valor y el
    almacenamiento — con timestamp de primer envío no hay que guardar keys
    para siempre).
- ⏳ Alternativa legitimada por la guía, a evaluar en R4: como los IDs los
  genera el cliente, `PUT /trips/{id}/expenses/{expenseId}` es idempotente sin
  maquinaria extra. R4 decide POST+key vs PUT-create.

## 6. Concurrencia: ETags y condicionales

- Toda operación que devuelve o modifica un recurso devuelve **`ETag`**.
- Updates con **`If-Match`** obligatorio en recursos editables (gastos,
  itinerario): precondición fallida → **`412 Precondition Failed`**.
- `GET` con `If-None-Match` → `304` (ahorra datos en móvil).
- Es el detector de conflictos del cliente offline: sin ETag, dos ediciones
  sin red = last-write-wins silencioso — en gastos, dinero perdido sin rastro.
  ⏳ R5 decide la política de resolución (LWW con reloj de servidor vs HLC);
  esta guía solo garantiza que el conflicto se DETECTA en el contrato.

## 7. Operaciones largas (LRO)

- Umbral: si el p99 supera **1 segundo**, se modela como LRO — aplica a
  liquidación del grupo (cálculo + notificaciones) y procesado de fotos.
- `202 Accepted` + header `operation-location` (URL absoluta del monitor).
- `GET <operation-location>` → `{ "id", "status":
  "NotStarted|Running|Succeeded|Failed|Canceled", "error", "result" }`.
- `retry-after` (segundos) en toda respuesta no terminal; el monitor se
  retiene ≥24 h — la app puede cerrarse y reabrirse sin perder el hilo.

## 8. Fechas, horas y duraciones

- Body y query: **RFC 3339** UTC — `YYYY-MM-DDTHH:mm:ss.sssZ`, máximo 3
  decimales (`format: date-time` en OpenAPI; mapea 1:1 a `Foundation.Date`).
- Los timestamps con autoridad son **de servidor** (premisa F3).
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
  como **string decimal** + `currencyCode` (en Postgres es `numeric`).
  ⏳ R3 confirma representación y reglas de rounding.
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
| `Idempotency-Key` | → | Obligatorio en POST-create (§5) |
| `x-client-request-id` | → | Opcional; el servidor lo devuelve tal cual |
| `x-request-id` | ← | Siempre — id opaco único (soporte: "mándame el id del error") |
| `x-error-code` | ← | En errores, espejo de `error.code` |
| `ETag` / `last-modified` | ← | En recursos (§6) |
| `retry-after` | ← | En `429`/`503`; la cola offline lo RESPETA en su backoff |

- Tolerancia: un header desconocido **nunca** hace fallar la petición.

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

- [ ] ¿Toda operación acepta `api-version` y está en el changelog del contrato?
- [ ] ¿Los errores nuevos añaden su `code` al enum contractual?
- [ ] ¿Las colecciones devuelven `value` + `nextLink` opaco?
- [ ] ¿Los POST-create requieren `Idempotency-Key`? ¿Los DELETE devuelven `204` siempre?
- [ ] ¿Los recursos editables llevan `ETag`/`If-Match` → `412`?
- [ ] ¿Los enums son extensibles? ¿Ningún campo `null` en respuestas? ¿Ningún dinero como number?
- [ ] ¿Campos de fecha en RFC 3339 con sufijo correcto? ¿Duraciones con unidad en el nombre?
- [ ] ¿Operaciones >1s p99 modeladas como LRO?
- [ ] ¿Ningún campo requerido añadido después de v1?

## Fuentes

- Azure REST API Guidelines (fuente principal):
  https://github.com/microsoft/api-guidelines/blob/vNext/azure/Guidelines.md
- Microsoft Graph REST API Guidelines (contraste, change tracking):
  https://github.com/microsoft/api-guidelines/blob/vNext/graph/GuidelinesGraph.md
- El `Guidelines.md` raíz del repo está deprecado y redirige a los dos anteriores.
- Idempotency-Key: convención Stripe / draft IETF `draft-ietf-httpapi-idempotency-key-header`.
