# Contrato de `POST /sync/upload` — el endpoint de la cola offline

**Tipo:** reference (Diátaxis) · **Origen:** bead R? (`TripSquad-iOS-0cd`) ·
**Fuentes:** ADR-0012 (idempotencia + cola), ADR-0013 (sync + tombstones),
ADR-0015 §2/§10/§11/§12 (la regla del camino, 429, 413, máquina de estados).

`/sync/upload` es **el punto más delicado del sistema**: por aquí pasan TODAS las
escrituras offline. La review lo marcó como P0 porque los ADRs decidieron *qué*
códigos usar pero no la *forma* del intercambio (shape del batch, respuesta por
operación, orden, atomicidad parcial, correlación). Este documento cierra ese hueco.

Es un **segundo contrato**, distinto del OpenAPI de la API directa (guía de
contrato §0): el codegen de OpenAPI **no** cubre esta ruta. La paridad entre ambos
la vigila el gate G6 (paridad RLS↔sync-rules), no el codegen.

---

## 0. El principio que manda: aquí NUNCA sale un 4xx (salvo 409)

Este es **el único endpoint** donde corre el gate **G1** (ADR-0015 §8): una
respuesta 4xx bloquea la cola de PowerSync para siempre (ADR-0012 §4). La regla del
camino (guía §0) vive aquí:

| Situación | Respuesta | Efecto en la cola |
|---|---|---|
| Batch procesado (todas las ops tienen desenlace terminal) | **200** + resultados por-op | `batch.complete()`; la cola avanza |
| Sobrecarga / rate limit | **503** + `retry-after` | el SDK reintenta el batch entero |
| Transitorio (BD caída, timeout, op en vuelo) | **5xx** | el SDK reintenta el batch entero |
| **JWT inválido / revocado** | **401** | el connector RE-AUTENTICA (ver abajo), no congela |
| **Nunca** | ~~400/409/412/413/422/429~~ | congelaría la cola |

Confirmado en la doc de PowerSync: *"a `4xx` or `5xx` response… the SDK will
repeatedly retry the upload, blocking the queue… return `2xx` responses for
validation or write conflicts and reserve error responses for transient issues"*.
Es decir, **4xx Y 5xx bloquean por igual** — de ahí que validación y conflicto
vayan en 200, y lo transitorio en 5xx/503.

El **409** (clave en vuelo) no puede ocurrir aquí: la cola de un cliente es FIFO y
un solo hilo, así que dos ops con la misma `Idempotency-Key` no viajan
concurrentemente. Si el adaptador devolviera `in_flight` (carrera con otro
dispositivo del mismo usuario), se trata como **transitorio → 5xx**, no como 409.

**El 401 es la excepción, y no la maneja PowerSync solo** (hallazgo P0 de Gemini,
matizado con la doc real): `uploadData()` es NUESTRO código, así que un `401` del
servidor no lo trata el SDK de forma especial — lo tratamos NOSOTROS en el connector.
El servidor devuelve **401** ante un JWT inválido/revocado; el connector lo **captura
y re-autentica** (refresh token, ADR-0012 §5) en vez de reintentar a ciegas, y solo
si el refresh falla pausa la cola y pide login. Como `fetchCredentials()` pide
credenciales frescas ANTES de cada flush, un 401 en vuelo es raro; pero cuando ocurre
(token revocado a mitad), este es el camino. **Sin este manejo, un 401 sí congelaría
la cola** — por eso es requisito del cliente, no solo del servidor.

---

## 1. Petición

```
POST /sync/upload?api-version=YYYY-MM-DD
authorization: Bearer <jwt>
content-type: application/json
```

Cuerpo — el `CrudBatch` de PowerSync traducido a nuestra forma. Cada operación
lleva su identidad de cliente y su clave de idempotencia derivada:

```json
{
  "clientId": "device-uuid-A",                 // UUID del esquema local, por dispositivo
  "ops": [
    {
      "opId": "op-8123",                       // CrudEntry.opId (correlación) — LOCAL al dispositivo
      "op": "PUT",                             // PUT | PATCH | DELETE
      "table": "expenses",
      "rowId": "9f3c…",                        // UUIDv7 de cliente = PK
      "tripId": "trip-abc",
      "idempotencyKey": "sha256(device-uuid-A|op-8123|expenses|9f3c…)",
      "firstSent": "2026-07-01T10:12:00Z",     // lo firma el CLIENTE en generación local (ADR-0015 §4)
      "ifMatch": "v7",                         // solo PATCH/DELETE de fila sincronizada
      "data": { … }                            // el estado; ausente en DELETE
    }
  ]
}
```

Reglas de la petición:

- **`api-version` obligatorio** (guía §2). Sin él o no soportado → esto es el
  ÚNICO caso donde el endpoint puede rechazar antes de tocar la cola; pero como un
  4xx la congela, un `api-version` inválido se trata como **error de despliegue del
  cliente** que no debería ocurrir (el cliente es generado). Si ocurre, **503** con
  log de alarma, no 400 — la cola no es rehén de un bug de versión.
- **⭐ `idempotencyKey` incluye el `clientId`** (hallazgo P0 de la voz externa
  Gemini — **corrige la fórmula de ADR-0012 §6**): `sha256(clientId ‖ opId ‖ table ‖
  rowId)`. El `opId` de PowerSync es un entero **local por dispositivo**, así que sin
  el `clientId` el iPhone y el iPad de la MISMA persona editando la MISMA fila
  generan `opId:5` los dos → misma clave → la segunda edición se tomaría como replay
  de la primera y **se perdería**. El `clientId` es un UUID del esquema local, uno
  por dispositivo. Sigue siendo determinista por op (no aleatoria por intento);
  reautenticar no la regenera.
- **`ifMatch`** solo en `PATCH`/`DELETE` de una fila **ya sincronizada**. Un `PUT`
  (create) no lo lleva: su protección es la PK de cliente (ADR-0015 §12).
- **`firstSent`** obligatorio: fija la ventana de 60 días (ADR-0012 §3).

### Tamaño del batch (el 413, ADR-0015 §10)

- **El cliente fragmenta** el `CrudBatch` en lotes de **≤ 100 ops** o **≤ 1 MB**,
  lo que se alcance antes. Un `batch.complete()` por fragmento.
- El servidor acepta cuerpos holgadamente por encima de ese límite. Si aun así se
  excede, responde **503** (no 413) en el camino de la cola.

---

## 2. Procesamiento: en orden, cada op idempotente, sin transacción gigante

**Las ops se aplican EN ORDEN** (FIFO, ADR-0012 §6: el endpoint es síncrono
respecto a la BD). Cada op corre en **su propia transacción** (la del adaptador,
`RepositorioPostgres.withTransaction`), no una transacción única para todo el batch.

Por qué per-op y no todo-o-nada: si la op 3 es un **rechazo permanente** (viaje
cerrado), NO debe deshacer las ops 1–2, que son válidas. Cada op es idempotente, así
que el modelo es:

```
para cada op en orden:
    r = aplicar(op)                    // guardar / actualizar / eliminar del adaptador
    si r es TRANSITORIO (5xx interno, in_flight, BD caída):
        → PARA. Devuelve 5xx. La cola reintenta el batch ENTERO.
          Las ops 1..(n-1) ya aplicadas se REPLAYAN (idempotencia = no-op).
    si r es PERMANENTE (rejected) o CONFLICTO:
        → anota el desenlace, escribe dead-letter, y CONTINÚA con la op siguiente.
devuelve 200 con el desenlace de cada op.
```

- **Transitorio → 5xx + para.** El SDK reintenta el batch completo; el dedupe
  estructural + la respuesta congelada hacen que re-aplicar lo ya hecho sea seguro.
- **Permanente / conflicto → sigue.** Se registra por-op y el batch termina en 200.

**El resultado de cada op se CONGELA por su `idempotencyKey`** (hallazgo P1 de
Gemini): la fila de `idempotency_keys` de esa op ES la tabla de "ops procesadas"
—guarda `outcome` + `etag`. Si el servidor commitea la op y muere antes de responder,
el retry del batch la reencuentra congelada y devuelve `replayed` con el mismo etag,
sin re-ejecutar. (Ya implementado en `RepositorioPostgres`: `reclamar` + `congelar`.)

**⚠️ Nada de efectos secundarios síncronos en este endpoint** (hallazgo P1 de
Gemini): notificaciones push, emails, integraciones externas van SIEMPRE por el
**transactional outbox** (ADR-0009 §4), nunca inline. Si la op 1 disparara una
notificación inline y la op 2 diera 5xx, el retry del batch la dispararía otra vez
(el dedupe protege la BD, no el efecto externo). El outbox se drena aparte, con su
propia idempotencia, así que un retry del batch no re-emite nada.

Traducción `CrudEntry` → caso de uso:

| `op` | Caso de uso | Notas |
|---|---|---|
| `PUT` sobre `expenses` | `CrearGasto` | create; sin `ifMatch` |
| `PATCH` sobre `expenses` | `EditarGasto` | `ifMatch` obligatorio |
| `DELETE` sobre `expenses` | `EliminarGasto` | `ifMatch` obligatorio; tombstone |
| acción (`:settle`, `:close`, `:leave`) | ⛔ **pendiente** | `:settle` no se codegenera hasta decidir su semántica (ADR-0015 §13). Hasta entonces, estas ops no viajan por la cola |

---

## 3. Respuesta 200: desenlace por operación, correlacionado por `opId`

```json
{
  "results": [
    { "opId": "op-8123", "outcome": "accepted",  "etag": "v8" },
    { "opId": "op-8124", "outcome": "replayed",  "etag": "v3" },
    { "opId": "op-8125", "outcome": "rejected",  "reason": "trip_closed" },
    { "opId": "op-8126", "outcome": "conflict",  "serverEtag": "v9" }
  ]
}
```

- **`outcome`** por op, mapeado desde el `ResultadoEscritura` del adaptador:
  `creado`/`actualizado` → `accepted`; `reproducido` → `replayed`; `rechazado` →
  `rejected` (+ `reason`); `conflicto` → `conflict` (+ `serverEtag`).
- **`opId`** correlaciona cada resultado con su `CrudEntry` — el cliente actualiza
  el estado local de esa fila (máquina de estados, ADR-0015 §12).
- **La respuesta es la señal INMEDIATA; las tablas sincronizadas son la durable.**
  Los `rejected` y `conflict` **también** se escriben en `write_rejections` /
  `write_conflicts` (server-side) y se sincronizan de vuelta, para que sobrevivan a
  que el cliente pierda la respuesta (dead-letter visible, ADR-0012 §4, ADR-0015 §2).
- El batch **siempre** cierra con `batch.complete()` cuando la respuesta es 200,
  aunque haya ops `rejected`/`conflict`: sus desenlaces ya están registrados y la
  cola debe avanzar.

### Correlación y orden

- El array `results` va en **el mismo orden** que `ops`, y además cada entrada
  lleva su `opId`: el cliente no depende del orden para correlacionar.
- **Todo o nada en la respuesta 200** (hallazgo P2 de Gemini): una respuesta 200
  DEBE incluir un resultado para CADA op enviada — el conector de PowerSync falla de
  forma opaca si el array no cuadra. El servidor **nunca omite** una op. Si el
  procesamiento se corta a mitad por un error transitorio, **no hay 200 parcial**: se
  responde **5xx** envolviendo el batch entero, sin array de resultados, y se
  reintenta completo. `200 ⟺ toda op tiene resultado`; `5xx ⟺ ningún resultado
  parcial`.

**PUT sobre una fila tombstoneada** (hallazgo P2 de Gemini): un `PUT` cuyo `rowId`
ya tiene tombstone → **`rejected: "deleted"`** (no resucita, ADR-0013 §5). Como los
`rowId` son UUID de cliente, recrear un gasto usa un id NUEVO, no el borrado; un PUT
sobre el id borrado solo puede ser un create rancio de la cola, y se rechaza.

---

## 4. Reautenticación antes del flush (ADR-0012 §5)

- Antes de cada flush, el connector pide credenciales frescas (`fetchCredentials()`,
  nunca cacheadas). JWT con < 60 s de vida → refresh token contra el servicio.
- **Reautenticar NO regenera las `Idempotency-Key`** (son deterministas del
  `CrudEntry`): si lo hiciera, el duplicado estaría garantizado.
- Refresh caducado/revocado → **no se vacía la cola ni se borra la base local**;
  se pide login. Al volver el MISMO usuario, el flush se reanuda con las claves
  intactas. Otro usuario → la cola del anterior no se sube con credenciales nuevas.

---

## 5. Invariantes verificables (gates)

| Gate | Qué prueba | Cómo |
|---|---|---|
| **G1** | Ninguna respuesta de `/sync/upload` es 4xx salvo 409 (y 409 es imposible aquí) | Test de contrato que enumera todos los caminos de error y assertea el status |
| **G1b** | Toda op enviada tiene exactamente un `result` con su `opId` | Test: batch de N ops → N results, opIds correlacionan |
| **G1c** | Reenviar un batch ya aplicado (retry) da los mismos `opId → outcome`, con `accepted` degradado a `replayed`, y no duplica filas | Test de integración: aplicar batch, reaplicar, comparar |
| **G4** | Dos `:settle` concurrentes con el mismo `settlementId` = una ejecución | (cuando `:settle` se defina) |

---

## 6. Lo que este contrato deja explícitamente para más tarde

- **`:settle` y demás acciones** por la cola: bloqueadas hasta decidir la semántica
  de `:settle` (ADR-0015 §13). El slice de gastos (PUT/PATCH/DELETE) no las necesita.
- **CRDTs / merge por campo**: hoy el conflicto es explícito (200 + `conflict`). Los
  CRDTs se activan por la señal de ADR-0013 §3 (>2 % de 412, o texto coeditado).
- **Compresión del cuerpo** (gzip): optimización, no contrato.

## Fuentes

- ADR-0012 §4/§5/§6 (cola, 4xx la congela, reauth, endpoint síncrono)
- ADR-0013 §2/§5 (ETag árbitro, tombstones)
- ADR-0015 §2/§10/§11/§12 (regla del camino, 413, 429, máquina de estados)
- PowerSync, *Writing client changes*: https://docs.powersync.com/handling-writes/writing-client-changes
- PowerSync, *Authentication setup*: https://docs.powersync.com/installation/authentication-setup
