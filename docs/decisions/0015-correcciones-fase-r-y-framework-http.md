# ADR-0015 — Framework HTTP (Hummingbird 2) y correcciones a la Fase R

- **Fecha:** 2026-07-14
- **Estado:** accepted
- **Firmado:** 2026-07-15 por Andrea ("mergea el PR y firma el ADR"). Recoge la
  elección de Hummingbird 2 y las correcciones P0 verificadas por tres voces
  externas (Codex, Gemini, MiniMax) en dos rondas. **Las decisiones de producto de
  la sección final (`:settle`, modo por defecto, FX, edición de gasto liquidado)
  quedan abiertas y vetables por ADR nuevo** — firmar este ADR no las cierra.
- **Dueña:** Andrea
- **Origen:** `/plan-eng-review` sobre ADR-0009, ADR-0011, ADR-0012, ADR-0013 y
  `docs/backend/guia-contrato-openapi.md`
- **Enmienda a:** ADR-0009 (§4), ADR-0011 (§2, §3, §8), ADR-0012 (§2, §4, §6),
  ADR-0013 (§2), guía de contrato (§3, §5, §6, §7, §9)

> Los ADR anteriores **no se editan** (regla 4 de la constitution: append-only).
> Este ADR los enmienda por escrito. Donde este documento y uno anterior
> discrepan, manda este.

## Contexto

La Fase R cerró seis ADR sin una línea de código. La review de ingeniería los
leyó **juntos** por primera vez, y ahí aparecieron dos contradicciones que ningún
documento podía ver desde dentro de sí mismo, más un hueco de arquitectura. La
review también resolvió la decisión que ADR-0009 dejó explícitamente abierta
("`/plan-eng-review` decide Hummingbird 2 vs Vapor").

## Decisión

### 1. Framework HTTP: **Hummingbird 2** (`from: "2.25.1"`)

Vapor obliga a elegir entre **congelado** y **alpha**, y ninguna de las dos
sirve para un equipo de una persona con presupuesto 0 €:

| | Hummingbird 2 | Vapor 4 | Vapor 5 |
|---|---|---|---|
| Última release estable | **2.25.1 — 2026-07-14** | 4.121.4 — **2026-04-10** | ninguna (`alpha.1`) |
| Concurrencia | `async/await` puro, Swift 6 estricto | `EventLoopFuture` (pre-async) | structured concurrency |
| Transporte OpenAPI | `swift-openapi-hummingbird` **compila** | `swift-openapi-vapor` sí | **NO EXISTE** |
| Commits humanos /12 m | 102 | 45 (mayoría bots) | — |
| Mantenedores | **1** (`adam-fowler`, 92 % de commits) | 3–4 | 3–4 |

**El dato que corta el nudo:** la arquitectura es contract-first (ADR-0008), y
`swift-openapi-vapor` declara `vapor from: 4.106.7`. **Contract-first + Vapor 5
no existe hoy.** Ir a Vapor 4 es firmar una migración 4→5 (reescritura de API).

Se acepta conscientemente el **bus factor 1** de Hummingbird. Es acotable: el
dominio es puro y el contrato es OpenAPI; lo único atado al framework son los
handlers y ~5 middlewares. Mitigaciones obligatorias desde el día 1:

- **Cero lógica de dominio en tipos de Hummingbird.** Los handlers solo traducen
  `Request` → caso de uso → `Response`.
- Los middlewares propios (idempotencia, ETag, rate limit) se escriben contra un
  **protocolo propio**, no directamente contra `RouterMiddleware`.
- `swift-openapi-hummingbird` se pinnea a `2.0.1` y se asume forkeable (sin
  release desde 2024-09-30; son pocos cientos de líneas).
- **Condición de revisión explícita:** el día que exista `vapor 5.0.0` estable
  **con** transporte OpenAPI, se reevalúa con un ADR nuevo.

Fuentes: API de GitHub y Context7, consultadas el 2026-07-14.

---

### 2. ⭐ El conflicto que llega por la cola **NO devuelve 412** (enmienda ADR-0013 §2)

**El agujero:** ADR-0013 §2 hace del `412` el árbitro oficial del conflicto,
incluido el del cliente que estuvo días sin red. ADR-0012 §4 dice que **cualquier
4xx bloquea la cola de PowerSync para siempre**. Las dos cosas no pueden ser
verdad. El escenario que ADR-0013 existe para resolver es el que, implementado
literalmente, **congela todas las escrituras pendientes** de esa persona.

**La regla correcta: el código HTTP depende del CAMINO, no del error.**

```
── Llamada DIRECTA de API (app en primer plano, con red) ───────────────
   If-Match no coincide  →  412 Precondition Failed        (sin cambios)

── Escritura que viene de la COLA de PowerSync ─────────────────────────
   If-Match no coincide  →  200 OK
                            { "status": "conflict",
                              "serverEtag": "…", "serverValue": {…},
                              "yourValue": {…} }
                         +  fila en write_conflicts  ──sync──▶  cliente

   ⇒ la cola AVANZA. La usuaria ve el conflicto y decide.
```

Es **la misma medicina** que ADR-0012 §4 ya aplicó a la key expirada
("200 + `write_rejections`, **no 412**"): el patrón estaba encontrado, solo
faltaba aplicarlo al conflicto.

**Fila que faltaba en la tabla de mapeo de ADR-0012 §4:**

| Situación | Respuesta al camino de la cola | Efecto |
|---|---|---|
| **Conflicto (ETag no coincide)** | **200** + `write_conflicts` | La cola avanza; la usuaria resuelve |

**Por qué NO vale el 409** (el único 4xx permitido): el 409 significa
"reinténtalo luego", y PowerSync lo reintenta. Pero un conflicto **no es
transitorio**: el cliente reintentaría con el **mismo ETag rancio** y recibiría
el mismo 409 eternamente. La cola no se bloquea por 4xx; se bloquea por bucle.
Mismo resultado, causa distinta.

**Invariante mecánica (gate de CI, §8):** ninguna respuesta del camino de la cola
puede ser 4xx salvo 409.

---

### 3. El motor de saldos es un **paquete compartido**, no una carpeta del servidor
(enmienda ADR-0011)

**El hueco:** ADR-0013 dice "el offline es el caso de uso" y ADR-0009 dice "iOS
hoy, Android/Kotlin después". Si solo el servidor calcula, el saldo no se mueve
al añadir un gasto sin cobertura — y la app parece rota. Luego el cliente calcula.
Luego Android lo reescribe en Kotlin. **Tres motores de dinero y nada que los
obligue a coincidir**, en la única parte del producto donde un error "invalida el
viaje" (ADR-0011, Contexto).

```
   TripSquadDomain  (paquete Swift, CERO dependencias — ni Foundation)
     ├── Motor de saldos · Dinero(Int64) · largest remainder · settle
     │
     ├──▶ lo importa el SERVICIO   (Linux · Hummingbird)
     └──▶ lo importa la APP iOS    (el MISMO código, literal)

   ⇒ servidor e iOS no PUEDEN divergir: es la misma lógica.
```

1. **El dominio es un paquete SwiftPM sin dependencias.** ADR-0011 §7 ya lo dice
   ("no depende de Foundation, así que el dominio puro sigue siendo portable");
   aquí se convierte en **restricción de empaquetado**, verificada por un test de
   dependencias entre módulos.
2. **El servidor sigue siendo la verdad.** El cliente calcula un saldo
   *optimista* para pintarlo ya; al sincronizar, el valor del servidor lo
   **reemplaza**. Jamás se liquida con el número del cliente.
3. **Vectores de oro** (`golden-vectors.json`) generados por las property tests
   de Swift, versionados en el repo. **Gate de CI en Swift y en Kotlin**: si el
   port de Android no los pasa, no mergea. Incluyen los casos de oro de
   ADR-0011 §7 (10 €/3, JPY zero-decimal, 1 céntimo entre 5, grupo de uno) y el
   contraejemplo del greedy `[−14,−13,+14,+13,+7,+11,−18]`.

---

### 4. Dinero: **`bigint` de céntimos** en Postgres (enmienda ADR-0011 §2 y guía §9)

La guía §9 dice "en Postgres es `numeric`". **Se corrige.**

Verificado en la doc de PowerSync (2026-07-14):

- El esquema del cliente **solo admite `text`, `integer` y `real`**
  ([client-sdk-references/swift](https://docs.powersync.com/client-sdk-references/swift)).
- `numeric`/`decimal` de Postgres → **`text`** en SQLite; *"these types have
  arbitrary precision in Postgres, so can only be represented accurately as text"*
  ([sync/types](https://docs.powersync.com/sync/types)). Es decir: PowerSync
  **no** rompe la precisión por sí solo.
- **Pero el casting es silencioso:** *"Casting between types should never error,
  but it may not fully represent the original data"* y *"**Nothing in PowerSync
  will fail hard**"*
  ([implementing-schema-changes](https://docs.powersync.com/maintenance-ops/implementing-schema-changes)).
  Si alguien declara la columna de dinero como `.real` en el `Schema` de Swift,
  entra un `Double` **sin error, sin warning y sin log** — y reaparece meses
  después como céntimos descuadrados.

**Decisión — el dinero es `Int64` de céntimos de punta a punta:**

```
  Postgres  bigint   ──PowerSync──▶  SQLite integer  ──▶  Swift Int64
  (int8 → integer es exacto: ambos son enteros de 64 bits con signo)

  String decimal + currencyCode  ⇢  SOLO en la frontera OpenAPI
                                    (Decimal(string:), nunca desde Double)
```

- Columnas de ADR-0011 §5 (`amount_original`, `amount_reference`) → **`bigint`**.
- **PROHIBIDO** declarar una columna de dinero como `.real` en el `Schema` del
  cliente. Es la **única** puerta por la que el `Double` puede entrar en el camino
  del dinero. Se vigila con un test (§8).
- El contrato OpenAPI **no cambia**: sigue viajando string decimal +
  `currencyCode` (guía §9). Cambia solo el almacenamiento.

---

### 5. `:settle` se dedupe como un gasto, no con `round` (enmienda ADR-0012 §2)

**El agujero:** ADR-0012 §2 declara
`CREATE UNIQUE INDEX ON settlements (trip_id, from_member, to_member, round)`
como el dedupe estructural — *"la capa 2 es la garantía"*. Pero **`round` no está
definido en ningún documento**. Y si el servidor lo derivase de la BD
(`max(round)+1`), el índice sería **inútil como red de seguridad**: una
re-ejecución calcularía un `round` nuevo y el índice no la vería. Justo cuando
más importa, porque `:settle` no es un create — **reejecutarlo re-dispara el
outbox y notifica a todo el squad**.

**Decisión — el mismo patrón que ya protege los gastos:**

- La acción `:settle` lleva un **`settlementId` (UUIDv7) generado en cliente**.
- Cada fila de liquidación tiene **PK determinista**, con el **índice de
  transferencia** dentro de la liquidación (0, 1, 2…), no solo el par:
  `id = uuidv5(settlementId, from_member ‖ to_member ‖ transferIndex)`.
  Sin el `transferIndex`, **dos transferencias del mismo deudor al mismo acreedor
  en la misma liquidación colisionarían** y `ON CONFLICT DO NOTHING` se comería una
  — perdiendo dinero, justo lo que el dedupe debía impedir (hallazgo de la voz
  externa Gemini). El orden `from ‖ to` es semántico (deudor→acreedor), no
  simétrico: `A→B` y `B→A` son transferencias legítimamente distintas.
- `INSERT … ON CONFLICT (id) DO NOTHING` ⇒ **la liquidación duplicada es
  físicamente imposible**, aunque toda la capa 1 falle.
- `UNIQUE (trip_id, settlement_id, from_member, to_member, transfer_index)` como
  refuerzo.
- **`round` queda como ordinal de presentación**, asignado por el servidor.
  **Jamás como clave de dedupe.**
- Los efectos de `:settle` (outbox, notificaciones) van **en la misma
  transacción** que las filas (ADR-0009 §4), así un replay no puede re-emitirlos.

**Nota:** una acción POST no es una fila CRUD, así que no entra sola en la cola de
PowerSync. Requiere una **tabla local de intención** (p. ej. `settlement_requests`)
que el `uploadData()` traduce a `POST /trips/{id}:settle`. ADR-0012 §6 lo daba por
supuesto sin escribirlo.

**⛔ `:settle` bloquea la generación de clientes hasta que Andrea decida su
semántica** (§13; hallazgo de la voz externa MiniMax). No es solo una decisión de
producto aplazada: es un bloqueo de la máquina contract-first (ADR-0008). El
OpenAPI de `:settle` no se puede generar sin saber si es sugerir / marcar pagado /
registrar pago. **Regla:** el endpoint `:settle` **no se codegenera** hasta la
decisión; **la Fase S arranca por los gastos** (create/edit), que no dependen de
ella. Así el slice vertical no se queda esperando a una decisión de producto.

---

### 6. Aislamiento: **`READ COMMITTED`**, no `SERIALIZABLE` (enmienda ADR-0012 §2)

ADR-0012 §2 pide la carrera de idempotencia "en transacción `SERIALIZABLE`".
Innecesario y contraproducente: bajo `SERIALIZABLE`, Postgres **aborta**
transacciones con `40001 serialization_failure`, y **nadie las reintenta** — se
convierten en 5xx bajo concurrencia. El diseño de Brandur usa locks de fila, no
`SERIALIZABLE`.

La sentencia que ya está en el ADR **es atómica por sí sola** bajo `READ COMMITTED`:

```sql
INSERT INTO idempotency_keys (user_id, idempotency_key, request_hash, locked_at, first_sent)
VALUES ($1, $2, $3, now(), $4)
ON CONFLICT (user_id, idempotency_key) DO UPDATE
  SET locked_at = now()
  WHERE idempotency_keys.locked_at IS NULL
RETURNING recovery_point, response_code, response_body, request_hash;
```

- 0 filas devueltas ⇒ la key está **en vuelo** por otro ⇒ **409**.
- Fila con respuesta congelada ⇒ **replay**.
- `request_hash` distinto ⇒ **422**.
- Si algún camino futuro necesitase `SERIALIZABLE` de verdad, **debe** llevar un
  bucle de reintento acotado sobre `40001`. No hay `SERIALIZABLE` sin ese bucle.

---

### 7. `:settle` es **síncrono**; el LRO se queda para las fotos (enmienda guía §7)

La guía §7 modela la liquidación como operación larga (`202` + `operation-location`
+ polling). **Choca con ADR-0012 §6**, que exige que el endpoint de escritura sea
*"síncrono respecto a la BD (nada de encolar para procesar luego), o se rompe la
consistencia de checkpoints de PowerSync"*.

Y el umbral de la guía (p99 > 1 s) **no se alcanza**: el cómputo para N ≤ 12
miembros son microsegundos. Lo lento son las notificaciones — y esas ya salen por
el **outbox**, de forma asíncrona, sin que la respuesta tenga que esperarlas.

- `:settle` responde **síncrono** (`200`/`201` + `Idempotency-Result`).
- **LRO se conserva solo para el procesado de fotos**, que nunca viaja por la cola
  de escrituras.

---

### 8. Barreras mecánicas (gates de CI, no buenas intenciones)

Cada corrección de arriba deja un test que la vigila. Sin el test, la corrección
se degrada sola:

| # | Gate | Qué mata |
|---|---|---|
| G1 | **Ninguna respuesta del camino de la cola es 4xx salvo 409** — test de contrato que enumera TODOS los caminos de error | La cola congelada (§2) |
| G2 | **Los vectores de oro pasan en Swift y en Kotlin** | La divergencia entre motores (§3) |
| G3 | **Ninguna columna de dinero se declara `.real`** en el `Schema` del cliente | El `Double` silencioso (§4) |
| G4 | **Dos `:settle` concurrentes con el mismo `settlementId` ⇒ una sola ejecución**, un solo outbox, una sola notificación | La liquidación duplicada (§5) |
| G5 | **Test de dependencias entre módulos:** `TripSquadDomain` no importa nada | El dominio contaminado (§3) |
| G6 | **Paridad RLS ↔ sync-rules** (ya en ADR-0013 §4) | El expulsado que sigue viendo |

---

### 9. Aplazados conscientemente

- **Circuit Breaker (ADR-0009 §4).** Con **una** dependencia, **un** llamante y
  **cero** usuarios, un breaker añade un modo de fallo propio (abrirse cuando no
  debía) a cambio de nada. Se implementa **la costura, no la máquina**: una
  política `Resilience` con retry + timeout hoy, y el breaker detrás de un flag
  cuando haya tráfico que proteger. No se re-litiga: se enciende, no se rediseña.

---

### 10. El `429` **también** congela la cola (extensión de §2)

Detectado por la voz externa (Codex). `429` es un 4xx. La guía §11 dice que la
cola offline *"RESPETA `retry-after`"* en un `429` — pero ADR-0012 §4 dice que
**cualquier 4xx salvo 409 bloquea la cola**. Es la misma contradicción de §2, en
otra ropa: **el rate limiting congelaría la cola de quien vuelve con 200
operaciones acumuladas** — justo el usuario al que más le importa.

**Regla:** en el camino de la cola, la sobrecarga se señaliza con **`503` +
`retry-after`**, nunca con `429`. El `429` se reserva a las llamadas directas de
API. Añadir a la tabla de mapeo:

| Situación | Respuesta al camino de la cola | Efecto |
|---|---|---|
| **Rate limit / sobrecarga** | **503** + `retry-after` | El SDK reintenta con backoff |

Queda cubierto por el gate **G1** (ninguna 4xx salvo 409 en el camino de la cola).

---

### 11. ⭐ Dónde corre el servicio: **Pi 5 + Cloudflare Tunnel** (0 €)

Detectado por la voz externa. **Era el agujero más grande del plan y no lo vio
nadie:** Supabase Free está decidido, PowerSync Free está decidido… y el servicio
Swift, que es el **único escritor del dominio**, **no tiene dónde correr**. La Pi
aparecía solo para backups y pings, no como plataforma.

**Decisión (presupuesto 0 €, coherente con ADR-0013 §6):**

- El servicio corre en la **Raspberry Pi 5** (contenedor, Swift en Linux ARM64).
- Se expone con **Cloudflare Tunnel** (`cloudflared`): TLS gestionado, dominio
  `api.tripsquad.app`, **sin IP pública, sin abrir puertos, sin router tocado**.
  Plan gratuito.
- **Se asume el trade-off, con los ojos abiertos:** la Pi es un SPOF doméstico.
  Aceptable **hasta lanzar**; el día que haya usuarios reales, migrar a un host
  gestionado es una decisión de gasto → **de Andrea**, vía ADR nuevo (misma regla
  que ADR-0013 §6 aplicó al salto de PowerSync/Supabase a Pro).
- **El ping nocturno no puede depender de la Pi** (si la Pi cae, se pausan los
  free tiers y nadie se entera). Segundo pinger **gratis** con **GitHub Actions
  cron** contra `/health`, y aviso si falla. Dos fuentes independientes.
- El backup `pg_dump` sigue en la Pi, pero ADR-0009 §5 ya exige **restaurarlo al
  menos una vez** — eso pasa de buena intención a tarea con fecha.

---

### 12. Estados de la escritura local (el hueco que la UI va a pagar)

Detectado por la voz externa. Con `write_rejections` (ADR-0012 §4) y ahora
`write_conflicts` (§2), el cliente maneja ya **seis** estados y ninguno está
escrito. Sin máquina de estados, la UI offline acaba siendo una colección de
parches.

```
   ┌─────────┐  encolada    ┌───────────┐   200 created    ┌──────────┐
   │ pending │─────────────▶│ uploading │─────────────────▶│ accepted │
   └─────────┘              └─────┬─────┘                  └──────────┘
                                  │        200 replayed         ▲
                                  ├─────────────────────────────┘
                                  │
                    200 rejected  │  200 conflict      5xx / 503
                       ┌──────────┼──────────┐            │
                       ▼          │          ▼            ▼
                 ┌──────────┐     │   ┌────────────┐  (reintenta
                 │ rejected │     │   │ conflicted │   con backoff,
                 └────┬─────┘     │   └─────┬──────┘   sigue uploading)
                      │           │         │
       reintentar ────┤           │         ├──── quedarme con la mía ──▶ pending
       copiar a otro ─┤           │         ├──── quedarme con la suya ─▶ accepted
       descartar ─────┘           │         └──── ver diferencias
       (SIEMPRE acto              │
        explícito de              │   409 (key en vuelo) → vuelve a pending
        la usuaria)               │
```

**`rejected` y `conflicted` son estados DISTINTOS y necesitan pantallas
distintas.** "No se pudo guardar: el viaje está cerrado" no es lo mismo que "Iván
cambió esto mientras no tenías cobertura".

**Regla para el `If-Match` que faltaba** (los creates no tienen ETag):

- **Create** (fila nacida en local, nunca sincronizada) → **no lleva `If-Match`**.
  Su protección es la **PK generada en cliente** + `ON CONFLICT DO NOTHING`.
- **Update/Delete de una fila ya sincronizada** → `If-Match` **obligatorio** con
  el ETag que el cliente conocía.
- **Update/Delete de una fila local aún no confirmada** → se resuelve **en local**
  (se colapsan las operaciones antes de subirlas); nunca viaja un `If-Match`
  inventado.

---

### 13. `:settle` — hay que decidir **qué significa liquidar** (⚠️ decisión de producto, pendiente)

Detectado por la voz externa, y es el más profundo. `:settle` mezcla **tres
conceptos** que el plan trata como uno:

| Concepto | ¿Muta dinero? | ¿Peligroso al reejecutar? |
|---|---|---|
| **(a) Calcular sugerencias** de quién paga a quién | No | No — es una lectura pura |
| **(b) Marcar deudas como saldadas** (cerrar una ronda) | **Sí** | **Sí** — outbox + notificaciones |
| **(c) Registrar un pago real** ("le hice un Bizum de 20 €") | **Sí** | **Sí** |

Todo el aparato de idempotencia de §5 (PK determinista, `settlementId`,
`ON CONFLICT DO NOTHING`) **solo hace falta para (b) y (c)**. Si `:settle` fuese
únicamente (a), sería un `GET` y no habría nada que deduplicar.

**Esto no lo decide la ingeniería.** Queda **abierto para Andrea**. Recomendación
de esta review: **(a) es un `GET /trips/{id}/settlement-suggestions`** (lectura
pura, sin idempotencia, cacheable) y **(c) es la acción POST peligrosa**
(`:record-payment`), que es la que necesita todo el aparato. **(b) probablemente
no exista** como concepto separado en un squad de amigos.

Hasta que se decida, §5 se dimensiona para el caso peor (b)+(c).

---

### 14. Aplazados que la voz externa señaló y NO se aceptan como recorte

- **Outbox sin worker definido** (Codex #16) — real. El worker se define en la
  Fase S con el slice de gastos: drena cada N segundos, retry con backoff,
  handlers idempotentes, y las notificaciones fallidas **no bloquean** la
  transacción de dominio. Se anota como tarea, no como ADR.
- **RLS + rol dedicado: falta el mecanismo** (Codex #8) — real y no trivial. El
  servicio usa un rol Postgres propio, así que las RLS de usuario **no se evalúan
  solas**: hacen falta `SET LOCAL role` + `request.jwt.claims`, o funciones
  `security definer`. **Se investiga antes de la primera escritura**, no después.
- **Hay DOS contratos, no uno** (Codex #7) — cierto: OpenAPI no cubre sync rules,
  esquema SQLite, buckets ni columnas locales. La afirmación "el contrato OpenAPI
  es la fuente única de verdad" (guía, línea 9) es **falsa tal como está escrita**
  y debe matizarse: es la fuente única **del contrato HTTP**. El contrato de sync
  es un segundo artefacto versionado, y la **paridad entre ambos** ya tiene su gate
  (G6).

---

### 15. Permisos de edición: **todos editan, todo queda registrado** (decisión de Andrea)

Firmado por Andrea el 2026-07-14: *"todos pueden editar pero se queda registrado"*.
Cierra el hueco #14 de la voz externa.

**Sin candados de permiso; con trazabilidad.** Cualquier miembro del viaje puede
editar cualquier gasto — no solo quien lo pagó, no hay rol de admin. Es coherente
con el resto del producto: la responsabilidad es **social**, no técnica. Es el
mismo argumento que sostiene el modo detallado de ADR-0011 §8.2 ("la trazabilidad
importa más que el número de Bizums").

**Sale casi gratis:** ADR-0013 §3 ya exige **"versionado por CAMPO, no por fila
entera"** como preparación de CRDTs. El historial de ediciones es ese mismo dato,
mirado desde el producto en vez de desde la sincronización.

```
  expense_revisions  (append-only, jamás UPDATE ni DELETE)
  ┌──────────────────────────────────────────────────────────┐
  │ id · expense_id · edited_by · edited_at (reloj servidor)  │
  │ field · old_value · new_value                            │
  └──────────────────────────────────────────────────────────┘

  En la app, bajo cada gasto:
    Cena en la playa            45,00 €
    Pagó Iván · dividido entre 4
    ─────────────────────────────────────────
    ✏️  Marta cambió el importe: 40,00 € → 45,00 €   ayer
    ✏️  Sara se añadió al reparto                     ayer
    [ ver historial completo ]
```

**Reglas concretas:**

- **Quién:** cualquier miembro del viaje. La autorización es `is_member(trip_id)`
  — la misma función única de ADR-0013 §4, ni una superficie más.
- **Qué se registra:** quién, cuándo (reloj del **servidor**, ADR-0013 §2), y el
  cambio **campo a campo**. Nunca "se editó": siempre "cambió el importe de 40 a 45".
- **`expense_revisions` es append-only para el reintento normal.** Ni `UPDATE` ni
  `DELETE` en operación corriente. Excepción: el borrado por RGPD (ver más abajo).
- **El `If-Match` sigue siendo obligatorio** (§2). "Todos pueden editar" no es
  "todos pueden pisar": dos ediciones concurrentes siguen dando conflicto, y el
  conflicto sigue siendo visible.
- **Viaje cerrado → no se edita.** Ya existe: ADR-0012 §4 lista `trip_closed` como
  rechazo permanente (200 + `write_rejections`).
- **Expulsado → no edita.** No es miembro; lo para la RLS, sin código nuevo.
- **⚠️ RGPD — corrección (hallazgo de las voces externas Gemini y MiniMax).** Una
  versión anterior de este ADR afirmaba que el historial "guarda `edited_by`, no
  datos personales". **Es falso:** `old_value`/`new_value` de un campo de **texto
  libre** (la descripción de un gasto: *"medicinas de Marta"*) SÍ es dato personal,
  y un `expense_revisions` puramente append-only lo conservaría **para siempre**,
  chocando con el tombstone estructural de ADR-0013 §5 (que hard-borra el
  contenido). Reglas:
  - Los campos **estructurales** (importe, divisa, `paidBy`, reparto) se guardan en
    claro **por necesidad contable** — son la trazabilidad que da sentido al
    historial. **Ojo (corrección de la voz externa Codex):** `paidBy` y el reparto
    SÍ son datos personales (identifican a personas); se conservan por la base
    legítima de llevar las cuentas del grupo, no porque "no sean personales". Al
    borrar el viaje se purgan como el resto.
  - Los campos de **texto libre** (descripción, notas) se versionan con el mismo
    **crypto-shredding** de ADR-0013 §5: el valor viejo se cifra con la clave del
    gasto; borrar la clave lo hace irrecuperable sin romper la fila. El derecho al
    olvido se ejerce borrando la clave, no la historia.
  - **Retención:** el historial se **purga al borrar el viaje** (o a los N meses de
    cerrarlo), no vive eternamente. Es un dato de servidor; al cliente baja solo el
    **último** valor + un contador de ediciones, no las 50 revisiones (evita
    inflar la SQLite del móvil — hallazgo de MiniMax).

**Sub-caso que queda abierto (vetable):** ¿qué pasa al **editar un gasto que ya
entró en una liquidación cerrada**? Cambia los saldos hacia atrás. Recomendación de
esta review, coherente con "todos editan, queda registrado": **se permite**, la
liquidación afectada se marca como *desfasada*, y el ajuste aparece como un
movimiento **nuevo y visible** — nunca como una mutación silenciosa del pasado.
Bloquearlo sería el único candado del sistema, y contradiría la decisión que acabas
de tomar.

## Consecuencias

- La guía de contrato debe actualizarse en **§3, §5, §6, §7 y §9**, y perder sus
  cinco marcadores `⏳` (apuntan a decisiones ya tomadas en R3/R4/R5 — es el
  artefacto del que se GENERA el código; rancio ahí = codegen equivocado).
- El esquema nace con `write_conflicts` además de `write_rejections`.
- La UI necesita **dos** pantallas honestas, no una: "rechazado" (ADR-0012 §4) y
  **"en conflicto"** (§2 de este ADR). Son estados distintos.
- El dominio se empaqueta como librería antes de escribir el primer handler.
- Los seis gates de §8 son requisitos de la Fase S, no deseos.
- El servicio tiene por fin **una casa** (Pi 5 + Cloudflare Tunnel) y el ping deja
  de depender de la misma máquina que vigila.
- La UI hereda una **máquina de estados de escritura** con seis estados, no dos.
- La frase "el contrato OpenAPI es la fuente única de verdad" se matiza: lo es del
  **contrato HTTP**. El de sync es un segundo artefacto.

## ⚠️ Decisiones de producto pendientes — solo Andrea

La review de ingeniería **no las toca**. Las deja nombradas para que no se pierdan:

1. **¿Qué significa `:settle`?** (§13). Cambia cuánta maquinaria de idempotencia
   hace falta de verdad. Recomendación: separar *sugerir* (GET puro) de *registrar
   un pago real* (POST peligroso).
2. **¿Modo detallado por defecto?** (ADR-0011 §8.2). La voz externa lo discute con
   un argumento fuerte: *"las apps de gastos existen porque reducen pagos; si el
   default conserva las deudas originales, puede parecer peor que Splitwise"*.
   ADR-0011 lo eligió por trazabilidad social ("¿por qué le pago a Marta si comí
   con Iván?"). **Las dos posturas son defendibles y la decisión es tuya.**
   La ingeniería solo aporta un dato: el modo simplificado **puede crear deudas
   entre personas que no se debían nada**, y eso es matemáticamente inevitable.
3. **¿FX ya o después?** La voz externa dice que está sobrediseñado para un MVP.
   Esta review **discrepa a medias**: las **columnas** son gratis hoy y carísimas
   después (migrar dinero ya escrito), pero la **superficie de contrato y UX** de
   multi-divisa sí se puede aplazar entera. Recomendación: **columnas sí, API y UI
   no** — MVP mono-divisa por viaje.
4. ~~¿Quién puede editar un gasto?~~ → **RESUELTA por Andrea (2026-07-14): "todos
   pueden editar pero se queda registrado".** Ver §15.

## Alternativas consideradas

- **Vapor 4** — estable pero congelado (sin release desde 2026-04-10) y con
  `EventLoopFuture`. Firma una migración 4→5 que es una reescritura de API.
- **Vapor 5** — donde queremos estar, pero `alpha.1`, con el servidor HTTP
  pinneado a un SHA de un paquete en `0.1.0-prerelease`, y **sin transporte
  OpenAPI**. Incompatible con contract-first hoy.
- **Mantener el 412 en la cola** — congela todas las escrituras pendientes de esa
  persona, en silencio y para siempre.
- **Usar 409 para el conflicto en la cola** — bucle infinito: el cliente reintenta
  con el mismo ETag rancio.
- **Que solo el servidor calcule saldos** — cero riesgo de divergencia y más
  simple, pero el saldo no se mueve al añadir un gasto sin cobertura. En una app
  de gastos que compite con Splitwise, eso se siente roto.
- **`numeric` + declarar la columna `.text` en el cliente** — funciona, pero mete
  un parseo de string en el camino caliente y una fuente de error nueva.

## Fuentes

- Hummingbird: https://github.com/hummingbird-project/hummingbird/releases · SSWG-0032: https://forums.swift.org/t/sswg-0032-hummingbird/70854
- Vapor 5 alpha: https://github.com/vapor/vapor/releases/tag/5.0.0-alpha.1 · https://blog.vapor.codes/posts/the-future-of-vapor/
- Transportes OpenAPI: https://github.com/hummingbird-project/swift-openapi-hummingbird · https://github.com/vapor/swift-openapi-vapor
- PowerSync, mapeo de tipos: https://docs.powersync.com/sync/types
- PowerSync, esquema de cliente (`text`/`integer`/`real`): https://docs.powersync.com/client-sdk-references/swift
- PowerSync, casting silencioso ("never fail hard"): https://docs.powersync.com/maintenance-ops/implementing-schema-changes
- PowerSync, un 4xx bloquea la cola: https://docs.powersync.com/handling-writes/writing-client-changes
- Brandur, idempotency keys en Postgres: https://brandur.org/idempotency-keys

*Datos de mantenimiento de frameworks (releases, commits, contribuidores) obtenidos
vía API de GitHub y Context7 el 2026-07-14.*
