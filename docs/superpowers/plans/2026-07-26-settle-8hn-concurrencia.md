# Concurrencia de `:settle` con DB real (8hn) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cerrar el corazón verificable del P0 `8hn` escribiendo el test de concurrencia real que faltaba (N `crear` del mismo settlement en paralelo → 1 fila), y reclasificar la parte de outbox/notificación a un bead diferido.

**Architecture:** Un `@Test` de integración nuevo en el suite Postgres existente, que reutiliza el helper `conBD` y ejerce el `ON CONFLICT DO NOTHING` sobre la clave natural bajo concurrencia real con `withThrowingTaskGroup`. No se añade código de producción: el invariante ya está implementado; esto cierra una brecha de cobertura. Después, tres comandos `bd` para reescribir el criterio, crear el bead diferido y cerrar `8hn`.

**Tech Stack:** Swift, swift-testing (`@Test`/`#expect`/`Issue.record`), PostgresNIO, Postgres 16, GitHub Actions (`adaptador-postgres.yml`), beads (`bd`).

## Global Constraints

- El test de integración se salta sin `PG_TEST=1` (`.enabled(if: pgHabilitado)`). CI lo corre con service container Postgres 16.
- Modelo vigente: ADR-0017 (`pending` → `confirm`). El criterio del bead se alinea a esto.
- Perfil git conservador (CLAUDE.md): no commitear/pushear salvo petición explícita. Cerrar `8hn` solo tras CI verde en `main`/`develop`, no en local.
- No construir outbox ni notificaciones (YAGNI: sin consumidor).
- `ResultadoSettle` = `.creado(id: String)` | `.duplicado(id: String)` | `.rechazado(razon: String)` (Equatable, Sendable).

---

### Task 1: Test de concurrencia real de `crear`

**Files:**
- Modify: `packages/TripSquadExpensesPostgres/Tests/TripSquadExpensesPostgresTests/SettlementPostgresTests.swift` (añadir un `@Test` dentro del `struct SettlementPostgresTests`, junto a `crearEsIdempotentePorClaveNatural`)

**Interfaces:**
- Consumes: `conBD(_:)` (helper del suite, entrega `(RepositorioPostgres, tripId)`), `Settlement.init(settlementId:tripId:from:to:transferIndex:amountMinor:createdBy:expiresAt:)`, `RepositorioPostgres.crear(_:) -> ResultadoSettle`, `RepositorioPostgres.pendientes(de:limit:ahora:) -> [(String, Settlement)]`, miembros `ana`/`ivan` del struct.
- Produces: nada consumido por otras tareas (test terminal).

- [ ] **Step 1: Escribir el test que falla/caracteriza**

Añadir dentro de `struct SettlementPostgresTests` (después de `crearEsIdempotentePorClaveNatural`, línea ~46):

```swift
/// G4 (bead 8hn) — invariante de concurrencia con DB real: N `crear` del MISMO
/// settlement EN PARALELO → exactamente 1 fila, 1 `.creado`, resto `.duplicado`.
/// Cubre el escenario que el criterio del P0 pedía y que solo estaba testeado en
/// secuencial (`crearEsIdempotentePorClaveNatural`). El `ON CONFLICT DO NOTHING`
/// sobre la clave natural lo hace determinista: un INSERT gana el `RETURNING`, el
/// resto cae al `SELECT` de la fila existente.
@Test func crearConcurrenteMismoSettlementDejaUnaSolaFila() async throws {
    try await conBD { repo, tripId in
        let s = Settlement(settlementId: "s-concurrente", tripId: tripId, from: ivan, to: ana,
                           transferIndex: 0, amountMinor: 2000, createdBy: ivan,
                           expiresAt: Date().addingTimeInterval(3600))
        let n = 8
        var resultados: [ResultadoSettle] = []
        try await withThrowingTaskGroup(of: ResultadoSettle.self) { group in
            for _ in 0..<n { group.addTask { try await repo.crear(s) } }
            for try await r in group { resultados.append(r) }
        }
        let creados = resultados.filter { if case .creado = $0 { return true }; return false }
        let duplicados = resultados.filter { if case .duplicado = $0 { return true }; return false }
        #expect(creados.count == 1, "exactamente un .creado bajo N inserts concurrentes")
        #expect(duplicados.count == n - 1, "el resto deben ser .duplicado")
        // Todos apuntan a la MISMA fila ganadora.
        guard case .creado(let idCreado) = creados.first else { Issue.record("falta .creado"); return }
        for case .duplicado(let idDup) in resultados {
            #expect(idDup == idCreado, "el duplicado devuelve el id de la fila ganadora")
        }
        // Una sola fila viva, verificada por la API pública (sin SQL crudo ni tocar `conBD`).
        let vivos = try await repo.pendientes(de: tripId, limit: 200, ahora: Date())
        #expect(vivos.count == 1, "una sola liquidación materializada")
    }
}
```

- [ ] **Step 2: Levantar Postgres local y aplicar migraciones**

```bash
docker run -d --name tripsquad-pg -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=tripsquad -p 5432:5432 postgres:16
sleep 4
cd "/Volumes/DiscoAndrea/Area de trabajo/02-Freelance/apps/TripSquad-iOS"
for f in db/migrations/*.sql; do PGPASSWORD=postgres psql -h localhost -U postgres -d tripsquad -v ON_ERROR_STOP=1 -f "$f"; done
```

- [ ] **Step 3: Correr el test**

```bash
PG_TEST=1 swift test --package-path packages/TripSquadExpensesPostgres \
  --filter "crearConcurrenteMismoSettlementDejaUnaSolaFila"
```

Expected: **PASS**. (Es un test de caracterización/regresión: el `ON CONFLICT` ya es
correcto en producción, así que no hay fase "red" genuina — el valor es cerrar la brecha
de cobertura concurrente que el bead daba por hecha.)

- [ ] **Step 4 (opcional — confirmar que el test muerde):** mutación temporal, NO commitear

En `RepositorioPostgres.crear` (`packages/TripSquadExpensesPostgres/Sources/TripSquadExpensesPostgres/RepositorioPostgres.swift:314`), cambiar temporalmente la línea `ON CONFLICT (...) DO NOTHING` por una clave imposible de colisionar (p. ej. `ON CONFLICT (id) DO NOTHING`, que ya no cubre la clave natural del test), volver a correr el Step 3 y confirmar que el test **FALLA** (aparecen errores de UNIQUE o múltiples `.creado`). Después `git checkout -- packages/TripSquadExpensesPostgres/Sources/TripSquadExpensesPostgres/RepositorioPostgres.swift` para revertir. Este paso valida la mordida del test sin dejar rastro.

- [ ] **Step 5: SwiftLint del archivo de test**

```bash
swiftlint lint packages/TripSquadExpensesPostgres/Tests/TripSquadExpensesPostgresTests/SettlementPostgresTests.swift
```

Expected: sin violaciones nuevas.

- [ ] **Step 6: Commit**

```bash
git add packages/TripSquadExpensesPostgres/Tests/TripSquadExpensesPostgresTests/SettlementPostgresTests.swift
git commit -m "test(settle): concurrencia real de crear con DB real (8hn G4)

N crear del mismo settlement en paralelo -> 1 fila, 1 .creado, resto
.duplicado. Cierra la brecha del P0 8hn, que solo estaba cubierto en
secuencial. Ejerce el ON CONFLICT DO NOTHING sobre la clave natural.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 7: Limpiar Postgres local**

```bash
docker rm -f tripsquad-pg
```

---

### Task 2: Revisión por otro modelo (Codex)

**Files:** ninguno (revisión).

- [ ] **Step 1:** Pasar el test nuevo por Codex (regla de validación cruzada, CLAUDE.md). Foco: ¿el `withThrowingTaskGroup` de verdad solapa las 8 inserciones sobre el pool del `PostgresClient`?, ¿hay alguna ventana en que un perdedor del `ON CONFLICT` vea "estado inconsistente" en lugar de `.duplicado`?, ¿`n=8` es suficiente sin ser caro?
- [ ] **Step 2:** Aplicar los ajustes que sobrevivan a criterio de Andrea. Si Codex propone subir/bajar `n`, ajustar la constante y re-correr Task 1 Step 3.

---

### Task 3: Reclasificar los beads (Parte B del spec)

**Files:** ninguno (base de datos de beads).

- [ ] **Step 1: Reescribir el criterio de `8hn` a ADR-0017**

```bash
bd update TripSquad-iOS-8hn --acceptance "Test de integracion con DB real: N crear concurrentes del mismo settlement -> 1 fila, 1 .creado, resto .duplicado. (outbox/notificacion diferidos: ver bead dependiente)"
```

- [ ] **Step 2: Crear el bead diferido de outbox/notificación**

```bash
bd create "Idempotencia del efecto lateral de :settle (1 evento/notificacion por transicion; reejecucion no duplica) via outbox" \
  --type task --priority 3 \
  --description "Cuando exista el subsistema de notificaciones (push/APNs), garantizar que cada transicion de settlement (confirm/reject/cancel) emite como maximo un evento/notificacion, y que reejecutar no duplica. Patron outbox: evento escrito en la misma tx que la transicion, dedupe por settlementId. Bloqueado por: diseno de notificaciones (no existe). Ref: ADR-0017, spec 2026-07-26-settle-8hn."
```

Anotar el id devuelto y marcarlo diferido:

```bash
bd update <id-nuevo> --status deferred
```

- [ ] **Step 3: Cerrar `8hn` — SOLO tras CI verde**

Tras mergear Task 1 y ver el job `adaptador-postgres` verde en CI (no en local):

```bash
bd close TripSquad-iOS-8hn --reason "Concurrencia con DB real cubierta por crearConcurrenteMismoSettlementDejaUnaSolaFila (verde en CI). Outbox/notif movidos a bead diferido."
```

---

## Self-Review

**1. Spec coverage:**
- Parte A (test concurrente N=8, 1 creado / resto duplicado / 1 fila, solo DB) → Task 1. ✅
- Nota de no-flakiness del spec → reflejada en el docstring del test y en Task 2 Step 1. ✅
- Parte B (reescribir criterio, bead diferido, cerrar tras verde) → Task 3. ✅
- Gates (swift test PG_TEST, SwiftLint, Codex, firma Andrea) → Task 1 Steps 3/5, Task 2, y cierre en Task 3. ✅

**2. Placeholder scan:** sin TBD/TODO; el test va con código completo; comandos concretos. ✅

**3. Type consistency:** `ResultadoSettle.creado(id:)`/`.duplicado(id:)`, `crear(_:)`, `pendientes(de:limit:ahora:)`, `conBD`, `pgHabilitado`, `ana`/`ivan` — todos verificados contra el código real. ✅
