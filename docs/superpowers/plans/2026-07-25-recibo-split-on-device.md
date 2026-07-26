# Recibo → split (on-device) — Implementation Plan

> **Referencia de diseño — no es un tracker.** El estado de ejecución y su avance viven en beads (bd), nunca en este documento. Los pasos de abajo son el plan de referencia (viñetas), no checkboxes de seguimiento. Ver AGENTS.md, sección Rules.

**Goal:** Recibir del móvil un recibo ya itemizado + asignado y crear el gasto repartido en céntimos exactos (estilo Apple Cash, pero en Europa y dentro del settle del grupo).

**Architecture:** El OCR/itemización vive en la app (on-device); el back solo hace la CUENTA. Una función pura de dominio `repartoDesdeRecibo` compone las primitivas ya testeadas (`repartoIgual` para ítems/compartidos + `repartoPorPeso` para prorratear impuestos/propina) y devuelve un `Reparto.exacto`. Un método fino `CasosDeUsoGastos.crearDesdeRecibo` construye el `Gasto` y delega en el `crear` existente (replay+auth+validación+persistencia). Una ruta `POST .../expenses/from-receipt` lo expone.

**Tech Stack:** Swift, TripSquadDomain (Int64 céntimos, ADR-0011), Hummingbird, swift-testing.

## Global Constraints

- Dinero: TODO importe es `Int64` de céntimos de la divisa de referencia (ADR-0011 §2). `Double` PROHIBIDO. La suma de cuotas es SIEMPRE exactamente el importe (conservación por construcción).
- El `importeMinor` del gasto se **deriva** de Σ ítems + impuestos + propina (no hay "total" externo que reconciliar → no hay bug de descuadre).
- Reutilizar SIEMPRE las primitivas del dominio (`repartoIgual`, `repartoPorPeso`) — no reimplementar aritmética de céntimos.
- El `actor` sale de `ctx.actor` (JWT), NUNCA del body. `Idempotency-Key` obligatoria (mismo patrón que `POST /expenses`).
- Auth: cualquier MIEMBRO puede crear un gasto; viaje cerrado lo rechaza (`ResultadoEscritura.rechazado`). Mismo gate que el `crear` normal (ADR-0015 §15).
- Overflow: toda suma de `Int64` usa `addingReportingOverflow` y lanza `DomainError.saldoFueraDeRango` (nunca SIGTRAP).
- **NOTA de alcance (reconciliar):** el spec menciona "sharers ⊆ miembros del viaje → reglaViolada". El camino de creación de gastos EXISTENTE (`CasosDeUsoGastos`) NO valida que los miembros del reparto sean del viaje (solo valida al ACTOR), y no tiene `ViajeRepositorio` inyectado. Para NO divergir del gasto normal ni meter wiring nuevo, este plan **no** añade la validación sharers⊆miembros; se deja como decisión a confirmar con Andrea (parity con gastos normales). Las validaciones estructurales (≥1 sharer, importes ≥ 0) SÍ van en el dominio.
- Tras cada tarea con código: `swift build` + `swift test` del paquete tocado en verde antes del commit. Tests Postgres (si aplica) con `PG_TEST=1` (Postgres local en :5432).

---

## File Structure

- `packages/TripSquadDomain/Sources/TripSquadDomain/RepartoDesdeRecibo.swift` — **crear**. `ItemRecibo` + `repartoDesdeRecibo(...)`.
- `packages/TripSquadDomain/Tests/TripSquadDomainTests/RepartoDesdeReciboTests.swift` — **crear**. Casos canónicos con mapas `.exacto` esperados.
- `packages/TripSquadExpenses/Sources/TripSquadExpenses/CasosDeUso.swift` — **modificar**. Añadir `crearDesdeRecibo(...)` a `CasosDeUsoGastos`.
- `packages/TripSquadExpenses/Tests/TripSquadExpensesTests/CasosDeUsoGastosDesdeReciboTests.swift` — **crear**.
- `packages/TripSquadService/Sources/TripSquadServiceCore/GastosRoutes.swift` — **modificar**. Añadir `POST .../expenses/from-receipt` + su DTO.
- `packages/TripSquadService/Tests/TripSquadServiceTests/GastosDesdeReciboRoutesTests.swift` — **crear**.
- `docs/decisions/00XX-recibo-split.md` — **crear** ADR (siguiente número libre ≥ 0025; 0023 está reservado para Brújula M8, 0024 es el wedge — verificar en `docs/decisions/`).

**Templates a leer antes:** `Reparto.swift` (primitivas `repartoIgual`/`repartoPorPeso`), `CasosDeUso.swift` (`crear`, `ResultadoEscritura`), `GastosRoutes.swift` (`POST expenses`, `respuestaDirecta`, `req.idempotencyKey()`), `GoldenVectors.swift` (el `.exacto` ya está cubierto downstream por el motor golden).

---

## Task 1: Dominio — `repartoDesdeRecibo`

**Files:**
- Create: `packages/TripSquadDomain/Sources/TripSquadDomain/RepartoDesdeRecibo.swift`
- Test: `packages/TripSquadDomain/Tests/TripSquadDomainTests/RepartoDesdeReciboTests.swift`

**Interfaces:**
- Consumes: `repartoIgual(importe:entre:pagador:)`, `repartoPorPeso(importe:pesos:)`, `Reparto`, `MiembroId`, `DomainError` (todos ya en el módulo).
- Produces:
```swift
public struct ItemRecibo: Equatable, Sendable {
    public let importeMinor: Int64
    public let sharers: [MiembroId]      // ≥ 1, sin duplicados
    public init(importeMinor: Int64, sharers: [MiembroId])
}
/// Reparto de un recibo: cada ítem se divide a partes iguales entre sus sharers
/// (céntimo sobrante al MiembroId menor), e impuestos+propina se prorratean
/// proporcionalmente al subtotal de cada persona (largest-remainder ponderado).
/// Devuelve `.exacto([MiembroId: total])`, cuya suma es Σ ítems + impuestos + propina.
public func repartoDesdeRecibo(items: [ItemRecibo], impuestosMinor: Int64, propinaMinor: Int64) throws -> Reparto
```

- **Step 1: Escribe los tests que fallan.**
```swift
import Testing
import TripSquadDomain

@Suite struct RepartoDesdeReciboTests {
    let a = MiembroId("a"), b = MiembroId("b"), c = MiembroId("c")

    // Suma == Σ ítems + impuestos + propina (conservación), vía `cuotas`.
    func exacto(_ r: Reparto) throws -> [MiembroId: Int64] {
        guard case .exacto(let m) = r else { Issue.record("no exacto"); return [:] }
        return m
    }

    @Test func itemsPropiosSinImpuestos() throws {
        // a: 1000, b: 500. Sin impuestos.
        let r = try repartoDesdeRecibo(items: [
            ItemRecibo(importeMinor: 1000, sharers: [a]),
            ItemRecibo(importeMinor: 500, sharers: [b]),
        ], impuestosMinor: 0, propinaMinor: 0)
        #expect(try exacto(r) == [a: 1000, b: 500])
    }

    @Test func itemCompartidoCentimoSobranteAlMiembroMenor() throws {
        // 1001 compartido entre a,b -> 501/500, el sobrante al menor por id (a).
        let r = try repartoDesdeRecibo(items: [
            ItemRecibo(importeMinor: 1001, sharers: [b, a]),
        ], impuestosMinor: 0, propinaMinor: 0)
        #expect(try exacto(r) == [a: 501, b: 500])
    }

    @Test func impuestosProporcionalAlSubtotal() throws {
        // subtotales a:1000, b:0? no. a:750, b:250 (items). Impuestos 100 -> 75/25.
        let r = try repartoDesdeRecibo(items: [
            ItemRecibo(importeMinor: 750, sharers: [a]),
            ItemRecibo(importeMinor: 250, sharers: [b]),
        ], impuestosMinor: 80, propinaMinor: 20)   // 100 total, 75/25
        #expect(try exacto(r) == [a: 825, b: 275])
    }

    @Test func unaSolaPersona() throws {
        let r = try repartoDesdeRecibo(items: [ItemRecibo(importeMinor: 900, sharers: [a])],
                                       impuestosMinor: 100, propinaMinor: 0)
        #expect(try exacto(r) == [a: 1000])
    }

    @Test func impuestoCero() throws {
        let r = try repartoDesdeRecibo(items: [
            ItemRecibo(importeMinor: 300, sharers: [a]),
            ItemRecibo(importeMinor: 300, sharers: [b, c]),  // 150 c/u
        ], impuestosMinor: 0, propinaMinor: 0)
        #expect(try exacto(r) == [a: 300, b: 150, c: 150])
    }

    @Test func itemSinSharersLanza() throws {
        #expect(throws: DomainError.sinParticipantes) {
            _ = try repartoDesdeRecibo(items: [ItemRecibo(importeMinor: 100, sharers: [])],
                                       impuestosMinor: 0, propinaMinor: 0)
        }
    }

    @Test func importeNegativoLanza() throws {
        #expect(throws: DomainError.importeNegativo) {
            _ = try repartoDesdeRecibo(items: [ItemRecibo(importeMinor: -5, sharers: [a])],
                                       impuestosMinor: 0, propinaMinor: 0)
        }
    }

    @Test func sumaConservaViaCuotas() throws {   // el .exacto cuadra con el importe derivado
        let r = try repartoDesdeRecibo(items: [
            ItemRecibo(importeMinor: 733, sharers: [a, b, c]),   // 245/244/244
        ], impuestosMinor: 67, propinaMinor: 0)
        let m = try exacto(r)
        let importe: Int64 = 733 + 67
        let g = Gasto(id: "g", pagadoPor: a, importeMinor: importe, reparto: r)
        #expect(try cuotas(de: g) == m)   // no lanza cuotasNoCuadran
        #expect(m.values.reduce(0, +) == importe)
    }
}
```

- **Step 2: Ejecuta y verifica que fallan.**
Run: `swift test --package-path packages/TripSquadDomain --filter RepartoDesdeReciboTests`
Expected: FAIL de compilación (`repartoDesdeRecibo`/`ItemRecibo` no existen).

- **Step 3: Implementa `RepartoDesdeRecibo.swift`.**
```swift
// Reparto de un recibo itemizado (momento mágico #2). El OCR/itemización es
// on-device; aquí solo la cuenta, componiendo primitivas ya testeadas (ADR-0011).
import Foundation

public struct ItemRecibo: Equatable, Sendable {
    public let importeMinor: Int64
    public let sharers: [MiembroId]
    public init(importeMinor: Int64, sharers: [MiembroId]) {
        self.importeMinor = importeMinor; self.sharers = sharers
    }
}

public func repartoDesdeRecibo(items: [ItemRecibo], impuestosMinor: Int64, propinaMinor: Int64) throws -> Reparto {
    guard !items.isEmpty else { throw DomainError.sinParticipantes }
    guard impuestosMinor >= 0, propinaMinor >= 0 else { throw DomainError.importeNegativo }

    // 1) Subtotal por persona = suma de su parte igual en cada ítem (sobrante al id menor).
    var subtotales: [MiembroId: Int64] = [:]
    for item in items {
        guard item.importeMinor >= 0 else { throw DomainError.importeNegativo }
        guard !item.sharers.isEmpty else { throw DomainError.sinParticipantes }
        try exigirSinDuplicados(item.sharers)
        // pagador = sharer menor por id -> el sobrante cae en él (orden por MiembroId).
        let pagador = item.sharers.min()!
        let porItem = repartoIgual(importe: item.importeMinor, entre: item.sharers, pagador: pagador)
        for (m, v) in porItem {
            let (s, ov) = (subtotales[m] ?? 0).addingReportingOverflow(v)
            guard !ov else { throw DomainError.saldoFueraDeRango }
            subtotales[m] = s
        }
    }

    // 2) Impuestos + propina, prorrateados proporcional al subtotal (porPeso).
    let (tax, ov) = impuestosMinor.addingReportingOverflow(propinaMinor)
    guard !ov else { throw DomainError.saldoFueraDeRango }

    var totales = subtotales
    if tax > 0 {
        // pesos = subtotales > 0 (a Int; en 64-bit Int == Int64). Los de subtotal 0
        // no pagan impuesto (peso 0 no es válido en porPeso).
        var pesos: [MiembroId: Int] = [:]
        for (m, sub) in subtotales where sub > 0 { pesos[m] = Int(sub) }
        guard !pesos.isEmpty else { throw DomainError.sinParticipantes }   // recibo con todo a 0 + impuesto
        let porTax = try repartoPorPeso(importe: tax, pesos: pesos)
        for (m, v) in porTax {
            let (s, ov2) = (totales[m] ?? 0).addingReportingOverflow(v)
            guard !ov2 else { throw DomainError.saldoFueraDeRango }
            totales[m] = s
        }
    }
    return .exacto(totales)
}
```

- **Step 4: Ejecuta y verifica que pasan.**
Run: `swift test --package-path packages/TripSquadDomain --filter RepartoDesdeReciboTests`
Expected: PASS (8 tests).

- **Step 5: Commit.**
```bash
git add packages/TripSquadDomain/Sources/TripSquadDomain/RepartoDesdeRecibo.swift \
        packages/TripSquadDomain/Tests/TripSquadDomainTests/RepartoDesdeReciboTests.swift
git commit -m "feat(recibo): repartoDesdeRecibo (dominio) — items + prorrateo proporcional -> exacto"
```

---

## Task 2: Caso de uso `crearDesdeRecibo` + endpoint

**Files:**
- Modify: `packages/TripSquadExpenses/Sources/TripSquadExpenses/CasosDeUso.swift` (añadir método a `CasosDeUsoGastos`)
- Modify: `packages/TripSquadService/Sources/TripSquadServiceCore/GastosRoutes.swift` (nueva ruta + DTO)
- Test: `packages/TripSquadExpenses/Tests/TripSquadExpensesTests/CasosDeUsoGastosDesdeReciboTests.swift`
- Test: `packages/TripSquadService/Tests/TripSquadServiceTests/GastosDesdeReciboRoutesTests.swift`

**Interfaces:**
- Consumes: `repartoDesdeRecibo` + `ItemRecibo` (Task 1); `CasosDeUsoGastos.crear`, `ComandoCrearGasto`, `ResultadoEscritura` (existentes); `respuestaDirecta`, `req.idempotencyKey()` (existentes).
- Produces:
```swift
extension CasosDeUsoGastos {
    /// Construye el Gasto (.exacto) desde un recibo y delega en `crear`
    /// (replay + auth + validación + persistencia). El importe se DERIVA del reparto.
    public func crearDesdeRecibo(tripId: String, gastoId: String, pagadoPor: MiembroId,
                                 items: [ItemRecibo], impuestosMinor: Int64, propinaMinor: Int64,
                                 actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura
}
```

- **Step 1: Escribe los tests del caso de uso que fallan.** Usa el `RepositorioEnMemoria` como triple (implementa `GastoRepositorio` + `Membresia`), montando un viaje con miembro `a`. Calca el estilo de los tests de `CasosDeUsoGastos` existentes (busca el fichero de tests de gastos para el setup).
```swift
@Test func creaGastoExactoDesdeRecibo() async throws {
    let f = try await fixtureGastos()   // viaje t1, miembro a y b
    let r = try await f.casos.crearDesdeRecibo(
        tripId: "t1", gastoId: "g1", pagadoPor: f.a,
        items: [ItemRecibo(importeMinor: 750, sharers: [f.a]),
                ItemRecibo(importeMinor: 250, sharers: [f.b])],
        impuestosMinor: 100, propinaMinor: 0, actor: f.a, idempotencyKey: "k1")
    guard case .creado = r else { Issue.record("esperaba creado, fue \(r)"); return }
    // el gasto persistido reparte 825/275 (75/25 de impuesto proporcional)
    let g = try await f.repo.gasto(id: "g1", en: "t1")
    #expect(g?.gasto.importeMinor == 1100)
    #expect(g?.gasto.reparto == .exacto([f.a: 825, f.b: 275]))
}

@Test func noMiembroEsRechazado() async throws {
    let f = try await fixtureGastos()
    let r = try await f.casos.crearDesdeRecibo(
        tripId: "t1", gastoId: "g2", pagadoPor: MiembroId("ext"),
        items: [ItemRecibo(importeMinor: 100, sharers: [MiembroId("ext")])],
        impuestosMinor: 0, propinaMinor: 0, actor: MiembroId("ext"), idempotencyKey: "k2")
    #expect(r == .rechazado(razon: "not_member"))
}

@Test func viajeCerradoEsRechazado() async throws {
    let f = try await fixtureGastos(cerrado: true)
    let r = try await f.casos.crearDesdeRecibo(
        tripId: "t1", gastoId: "g3", pagadoPor: f.a,
        items: [ItemRecibo(importeMinor: 100, sharers: [f.a])],
        impuestosMinor: 0, propinaMinor: 0, actor: f.a, idempotencyKey: "k3")
    #expect(r == .rechazado(razon: "trip_closed"))
}

@Test func reciboInvalidoEsRechazado() async throws {   // ítem sin sharers
    let f = try await fixtureGastos()
    let r = try await f.casos.crearDesdeRecibo(
        tripId: "t1", gastoId: "g4", pagadoPor: f.a,
        items: [ItemRecibo(importeMinor: 100, sharers: [])],
        impuestosMinor: 0, propinaMinor: 0, actor: f.a, idempotencyKey: "k4")
    #expect(r == .rechazado(razon: "invalid_receipt"))
}

@Test func replayDevuelveReproducido() async throws {
    let f = try await fixtureGastos()
    let mk = { try await f.casos.crearDesdeRecibo(
        tripId: "t1", gastoId: "g5", pagadoPor: f.a,
        items: [ItemRecibo(importeMinor: 100, sharers: [f.a])],
        impuestosMinor: 0, propinaMinor: 0, actor: f.a, idempotencyKey: "k5") }
    _ = try await mk()
    let r2 = try await mk()
    guard case .reproducido = r2 else { Issue.record("esperaba reproducido"); return }
}
```

- **Step 2: Ejecuta y verifica que fallan.**
Run: `swift test --package-path packages/TripSquadExpenses --filter CasosDeUsoGastosDesdeReciboTests`
Expected: FAIL (no existe `crearDesdeRecibo`).

- **Step 3: Implementa `crearDesdeRecibo`** en `CasosDeUso.swift` (extensión o método dentro de `CasosDeUsoGastos`):
```swift
public func crearDesdeRecibo(tripId: String, gastoId: String, pagadoPor: MiembroId,
                             items: [ItemRecibo], impuestosMinor: Int64, propinaMinor: Int64,
                             actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura {
    let reparto: Reparto
    do { reparto = try repartoDesdeRecibo(items: items, impuestosMinor: impuestosMinor, propinaMinor: propinaMinor) }
    catch { return .rechazado(razon: "invalid_receipt") }
    // importe derivado del reparto (suma segura); no hay total externo que reconciliar.
    guard case .exacto(let totales) = reparto else { return .rechazado(razon: "invalid_receipt") }
    var importe: Int64 = 0
    for v in totales.values {
        let (s, ov) = importe.addingReportingOverflow(v)
        guard !ov else { return .rechazado(razon: "invalid_receipt") }
        importe = s
    }
    let gasto = Gasto(id: gastoId, pagadoPor: pagadoPor, importeMinor: importe, reparto: reparto)
    return try await crear(ComandoCrearGasto(tripId: tripId, gasto: gasto, actor: actor, idempotencyKey: idempotencyKey))
}
```
(Si `crear` es `public` en el mismo `struct`, el método puede ir dentro del `struct`; si va en `extension`, `crear` y las props que use deben ser accesibles — `crear` ya es `public`, así que la extensión funciona.)

- **Step 4: Verifica los tests del caso de uso.**
Run: `swift test --package-path packages/TripSquadExpenses --filter CasosDeUsoGastosDesdeReciboTests`
Expected: PASS.

- **Step 5: Escribe los tests de ruta que fallan.** Calca `GastosRoutesTests` (busca el fichero; mismo harness de app + JWT + header `Idempotency-Key`). Casos: POST from-receipt con body válido → 201 + etag; sin `Idempotency-Key` → 400 `missing_idempotency_key`; body con ítem sin sharers → 422 `invalid_receipt`; actor no-miembro → 422 `not_member`.

- **Step 6: Ejecuta y verifica que fallan.**
Run: `swift test --package-path packages/TripSquadService --filter GastosDesdeReciboRoutesTests`
Expected: FAIL (no existe la ruta).

- **Step 7: Implementa la ruta** en `GastosRoutes.swift`, dentro de `montarGastos`, calcando `POST expenses`:
```swift
// POST /trips/:tripId/expenses/from-receipt — crear gasto desde recibo itemizado
router.post("trips/:tripId/expenses/from-receipt") { req, ctx -> Response in
    let actor = ctx.actor
    guard let key = req.idempotencyKey() else { return errorJSON(.badRequest, "missing_idempotency_key") }
    let tripId = try ctx.parameters.require("tripId")
    let dto = try await req.decode(as: ReciboDTO.self, context: ctx)
    let items = dto.items.map { ItemRecibo(importeMinor: $0.importeMinor, sharers: $0.sharers.map(MiembroId.init)) }
    let r = try await deps.casos.crearDesdeRecibo(
        tripId: tripId, gastoId: dto.gastoId, pagadoPor: MiembroId(dto.pagadoPor),
        items: items, impuestosMinor: dto.impuestosMinor, propinaMinor: dto.propinaMinor,
        actor: actor, idempotencyKey: key)
    return respuestaDirecta(r)
}
```
Y el DTO (en `GastosRoutes.swift` o `DTOs.swift`, donde vive `GastoDTO`):
```swift
struct ReciboItemDTO: Decodable { let importeMinor: Int64; let sharers: [String] }
struct ReciboDTO: Decodable {
    let gastoId: String
    let pagadoPor: String
    let items: [ReciboItemDTO]
    let impuestosMinor: Int64
    let propinaMinor: Int64
}
```

- **Step 8: Verifica los tests de ruta + build del paquete.**
Run: `swift test --package-path packages/TripSquadService --filter GastosDesdeReciboRoutesTests`
Expected: PASS. Luego `swift build --package-path packages/TripSquadService`.

- **Step 9: Commit.**
```bash
git add packages/TripSquadExpenses/Sources/TripSquadExpenses/CasosDeUso.swift \
        packages/TripSquadExpenses/Tests/TripSquadExpensesTests/CasosDeUsoGastosDesdeReciboTests.swift \
        packages/TripSquadService/Sources/TripSquadServiceCore/GastosRoutes.swift \
        packages/TripSquadService/Sources/TripSquadServiceCore/DTOs.swift \
        packages/TripSquadService/Tests/TripSquadServiceTests/GastosDesdeReciboRoutesTests.swift
git commit -m "feat(recibo): crearDesdeRecibo + POST /expenses/from-receipt"
```

---

## Task 3: ADR + build/test completo

**Files:**
- Create: `docs/decisions/00XX-recibo-split.md` (siguiente número libre ≥ 0025)

- **Step 1: Escribe el ADR** (usa `_TEMPLATE.md`). Registra: OCR/itemización on-device (el back no parsea); descarte del free tier de Gemini por RGPD/términos UE (contexto); `repartoDesdeRecibo` compone `.igual`+`.porPeso`→`.exacto` reusando el motor testeado; impuestos/propina proporcional al subtotal (estilo Apple); importe derivado; el gasto entra por el `crear` existente y alimenta el settle; endpoint `POST .../expenses/from-receipt`. NOTA la decisión pendiente de "sharers⊆miembros" (parity con gastos normales). Enlaza el spec `docs/superpowers/specs/2026-07-25-recibo-split-on-device-design.md`. Verifica el nº libre (0023 = Brújula M8, 0024 = wedge).

- **Step 2: Build + test de los paquetes tocados.**
Run: `for p in TripSquadDomain TripSquadExpenses TripSquadService; do swift build --package-path packages/$p && swift test --package-path packages/$p; done`
Expected: verde.

- **Step 3: Commit.**
```bash
git add docs/decisions/00XX-recibo-split.md
git commit -m "docs(recibo): ADR de recibo->split on-device"
```

---

## Self-Review (cobertura del spec)

- **OCR on-device / back solo la cuenta** → Tasks 1-2 (el back no parsea nada). ✅
- **`repartoDesdeRecibo` reusa .igual + .porPeso → .exacto** → Task 1 + tests. ✅
- **Impuestos/propina proporcional al subtotal; ítems compartidos a partes iguales; sobrante determinista** → Task 1 (repartoPorPeso + repartoIgual con pagador=menor). ✅
- **Importe derivado (sin reconciliar total externo)** → Task 2 `crearDesdeRecibo`. ✅
- **Alimenta el settle vía el `crear` existente** → Task 2 delega en `crear`. ✅
- **Endpoint `POST .../expenses/from-receipt`, auth miembro, viaje cerrado, idempotencia** → Task 2 (reusa el pipeline de `crear`). ✅
- **Validación estructural (≥1 sharer, importes ≥ 0) → rechazo** → Task 1 lanza + Task 2 mapea a `invalid_receipt`. ✅
- **Golden vectors** → el `.exacto` producido ya está cubierto por el motor golden downstream; Task 1 añade casos canónicos con mapas esperados (no hace falta extender el generador JSON). ✅
- **Fuera de alcance (OCR, foto al gasto/FotoStorage, moneda extranjera/FX)** → sin tareas, correcto.
- **DEVIACIÓN a reconciliar:** sharers⊆miembros NO se valida (parity con gastos normales); anotado en Global Constraints + ADR, a confirmar con Andrea.
