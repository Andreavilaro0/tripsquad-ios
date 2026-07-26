---
título: "Dividir y reclasificar 8hn — concurrencia de :settle con DB real"
fecha: 2026-07-26
bead: TripSquad-iOS-8hn
adr: ADR-0017
estado: aprobado (diseño)
---

# Dividir y reclasificar `8hn` — concurrencia de `:settle` con DB real

## Contexto

`8hn` (P0) es el único P0 abierto. Su criterio original pedía:

> Test de integración con DB real: dos POST concurrentes → 1 liquidación, 1 outbox, 1 notificación.

Al revisar el código, el terreno ha cambiado respecto a cuando se escribió el bead:

1. **La garantía de "1 liquidación" existe en producción.** `RepositorioPostgres.crear`
   (`packages/TripSquadExpensesPostgres/Sources/TripSquadExpensesPostgres/RepositorioPostgres.swift:307`)
   hace `INSERT … ON CONFLICT (trip_id, settlement_id, from_member, to_member, transfer_index)
   DO NOTHING RETURNING id`. Si el `RETURNING` trae fila → `.creado`; si no → `SELECT` de la
   existente → `.duplicado`. Es atómico a nivel de fila.

2. **Pero el escenario concurrente NO está testeado.** El único test con DB real es
   `SettlementPostgresTests.crearEsIdempotentePorClaveNatural`, que crea **dos veces en
   secuencia** (creado, duplicado). No hay ningún test que lance N `crear` **en paralelo**.
   Los `withThrowingTaskGroup` del suite son el *setup* (`conBD`), no tests de concurrencia.
   → El bead afirmaba una cobertura que no existe.

3. **El modelo cambió (ADR-0017).** Crear un pago ya no notifica a todo el squad: es
   `pending` → la contraparte confirma/rechaza. El escenario "reejecutar re-dispara el outbox
   y avisa a todos" que hacía a esto "la acción más peligrosa del contrato" ya no aplica tal
   cual.

4. **El outbox y las notificaciones no existen.** No hay puerto en `Puertos.swift`, ni tabla
   en `db/migrations/`, ni despachador, ni consumidor (push/APNs). Construirlos solo para
   cerrar el test sería especulativo (YAGNI).

**Decisión (Andrea, 2026-07-26):** dividir y reclasificar. Cerrar la parte verificable hoy;
diferir outbox+notificación a cuando exista el subsistema de notificaciones.

## Parte A — Test de concurrencia real (el trabajo)

Nuevo `@Test` en `SettlementPostgresTests` (mismo archivo, reutiliza `conBD`):

- Lanza **N `repo.crear(s)` del mismo `Settlement`** en paralelo con `withThrowingTaskGroup`,
  recogiendo cada `ResultadoSettle`. Valor de N: **8** (suficiente para forzar la carrera sin
  encarecer CI).
- Aserciones:
  - exactamente **1** resultado `.creado`
  - los **N−1** restantes son `.duplicado`, y todos devuelven **el mismo `id`** que el `.creado`
  - `SELECT count(*)` sobre la clave natural (`trip_id, settlement_id, from_member,
    to_member, transfer_index`) = **1**
- Se salta sin `PG_TEST=1` (`.enabled(if: pgHabilitado)`, como el resto del suite); CI lo
  corre con el service container de Postgres.

**No se añade** un equivalente HTTP en-memoria: la garantía de producción es el `ON CONFLICT`
de Postgres; un test de concurrencia sobre el repo en-memoria sería más frágil y menos
representativo. (Reevaluable si se quiere cubrir la capa de rutas explícitamente.)

### Nota de no-flakiness

Bajo N inserts concurrentes del mismo settlement, el `ON CONFLICT DO NOTHING` deja que
exactamente un INSERT gane el `RETURNING`; los perdedores no devuelven fila y caen al `SELECT`
de la existente. Como cada `crear` es una query autocommit, el ganador commitea de inmediato y
los perdedores ven la fila. La UNIQUE natural garantiza una sola fila. Determinista.

## Parte B — Reclasificación

- **Reescribir el criterio de `8hn`** a la realidad ADR-0017:
  > Test de integración con DB real: N `crear` concurrentes del mismo settlement → 1 fila,
  > 1 `.creado`, resto `.duplicado`.
  Quitar "1 outbox, 1 notificación". Cerrar `8hn` cuando el test de la Parte A pase en CI.
- **Crear un bead nuevo, dependiente y diferido:**
  > Idempotencia del efecto lateral de `:settle` (1 evento/notificación por transición de
  > settlement; reejecución no duplica) vía patrón outbox.
  Bloqueado por: diseño del subsistema de notificaciones (no existe aún). Referencia ADR-0017.
  No se construye ahora.

## Gates de calidad

`swift test` con `PG_TEST=1` (Postgres levantado), SwiftLint, revisión del test por otro
modelo (Codex), aprobación de Andrea.

## Fuera de alcance

- Patrón outbox y su tabla/puerto.
- Subsistema de notificaciones (push/APNs) y su despachador.
- Test de concurrencia a nivel HTTP/rutas.
