# `:settle` — Sugerir (GET) + Registrar pago (POST) — Implementation Plan

> **Referencia de diseño — no es un tracker.** El estado de ejecución y su avance viven en beads (bd), nunca en este documento. Los pasos de abajo son el plan de referencia (viñetas), no checkboxes de seguimiento. Ver AGENTS.md, sección Rules.

**Goal:** Implementar los dos recursos de `:settle` decididos en ADR-0016: `GET /trips/:tripId/settlement/suggestion` (lectura pura) y `POST /trips/:tripId/settlements` (registro idempotente de un pago real).

**Architecture:** Clean Architecture, igual que Expenses. El dominio ya calcula las sugerencias (`liquidar`). Se añade: un modelo `Settlement` + puerto `SettlementRepositorio` en `TripSquadExpenses`, su implementación en `RepositorioEnMemoria`, un caso de uso, y dos handlers HTTP en `TripSquadService`. La idempotencia del POST es la de ADR-0015 §5 (dedupe estructural por `settlementId`), NO la (actor, key) de los gastos.

**Tech Stack:** Swift 6.1, Hummingbird 2, la tabla `settlements` ya existente (db/migrations/0001_expenses.sql).

## Global Constraints

- Dinero SIEMPRE en `Int64` de céntimos (`amountMinor`). Nunca Double.
- El dominio (`TripSquadDomain`) es PURO: sin dependencias externas (gate CI bead 9dn). El modelo `Settlement` y el puerto van en `TripSquadExpenses`, no en el dominio.
- El actor sale del JWT verificado (`ctx.actor`), nunca del body (ADR-0014 §5).
- El POST es una escritura: si algún día va por `/sync/upload`, obedece G1 (nunca 4xx salvo 409). En la API directa el conflicto/duplicado se resuelve en 200/201 idempotente, no en 4xx.
- Idempotencia del settlement: por `settlementId` de cliente + `transfer_index` (ADR-0015 §5), NO por (actor, idempotencyKey). Reintentar el mismo `settlementId` no duplica.
- ADR-0016 es la fuente de la decisión de producto.

---

### Task 1: Modelo `Settlement` + cálculo de la clave determinista

**Files:**
- Create: `packages/TripSquadExpenses/Sources/TripSquadExpenses/Settlement.swift`
- Test: `packages/TripSquadExpenses/Tests/TripSquadExpensesTests/SettlementTests.swift`

**Interfaces:**
- Consumes: `MiembroId` (de TripSquadDomain).
- Produces:
  - `struct Settlement { let settlementId: String; let tripId: String; let from: MiembroId; let to: MiembroId; let transferIndex: Int; let amountMinor: Int64 }`
  - `extension Settlement { var idDeterminista: String }` — `"\(settlementId)|\(from.raw)|\(to.raw)|\(transferIndex)"` (la PK que la tabla materializa como uuidv5; en dominio basta la cadena estable).

- **Step 1: Write the failing test**

```swift
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Settlement — clave determinista")
struct SettlementTests {
    @Test func idEstableParaLosMismosCampos() {
        let a = Settlement(settlementId: "s1", tripId: "t1", from: MiembroId("ana"), to: MiembroId("ivan"), transferIndex: 0, amountMinor: 2000)
        let b = Settlement(settlementId: "s1", tripId: "t1", from: MiembroId("ana"), to: MiembroId("ivan"), transferIndex: 0, amountMinor: 9999)
        // El importe NO entra en la clave: dos registros del mismo pago colisionan.
        #expect(a.idDeterminista == b.idDeterminista)
    }
    @Test func idDistintoPorTransferIndex() {
        let a = Settlement(settlementId: "s1", tripId: "t1", from: MiembroId("ana"), to: MiembroId("ivan"), transferIndex: 0, amountMinor: 2000)
        let b = Settlement(settlementId: "s1", tripId: "t1", from: MiembroId("ana"), to: MiembroId("ivan"), transferIndex: 1, amountMinor: 2000)
        #expect(a.idDeterminista != b.idDeterminista)
    }
}
```

- **Step 2: Run test to verify it fails**

Run: `cd packages/TripSquadExpenses && swift test --filter SettlementTests`
Expected: FAIL — `cannot find 'Settlement' in scope`.

- **Step 3: Write minimal implementation**

```swift
import TripSquadDomain

/// Un pago real registrado entre dos miembros (ADR-0016 concepto c). Append-only:
/// no borra deudas, es una entrada nueva que el cálculo de saldos incorpora.
public struct Settlement: Equatable, Sendable {
    public let settlementId: String   // generado en cliente; ancla de idempotencia
    public let tripId: String
    public let from: MiembroId
    public let to: MiembroId
    public let transferIndex: Int
    public let amountMinor: Int64
    public init(settlementId: String, tripId: String, from: MiembroId, to: MiembroId, transferIndex: Int, amountMinor: Int64) {
        self.settlementId = settlementId; self.tripId = tripId
        self.from = from; self.to = to
        self.transferIndex = transferIndex; self.amountMinor = amountMinor
    }
}

public extension Settlement {
    /// Clave de dedupe estructural (ADR-0015 §5). El importe NO entra: reintentar el
    /// mismo pago con otro importe sigue siendo el mismo pago (ON CONFLICT DO NOTHING).
    /// La BD la materializa como uuidv5(settlementId, from||to||transferIndex).
    var idDeterminista: String { "\(settlementId)|\(from.raw)|\(to.raw)|\(transferIndex)" }
}
```

- **Step 4: Run test to verify it passes**

Run: `cd packages/TripSquadExpenses && swift test --filter SettlementTests`
Expected: PASS (2 tests).

- **Step 5: Commit**

```bash
git add packages/TripSquadExpenses/Sources/TripSquadExpenses/Settlement.swift packages/TripSquadExpenses/Tests/TripSquadExpensesTests/SettlementTests.swift
git commit -m "feat(settle): modelo Settlement + clave determinista (ADR-0016)"
```

---

### Task 2: Puerto `SettlementRepositorio` + caso de uso `registrarPago`

**Files:**
- Modify: `packages/TripSquadExpenses/Sources/TripSquadExpenses/Puertos.swift` (añadir el puerto al final)
- Create: `packages/TripSquadExpenses/Sources/TripSquadExpenses/CasosDeUsoSettle.swift`
- Test: `packages/TripSquadExpenses/Tests/TripSquadExpensesTests/CasosDeUsoSettleTests.swift`

**Interfaces:**
- Consumes: `Settlement`, `Membresia` (existente), `ResultadoSettle` (nuevo, abajo).
- Produces:
  - `protocol SettlementRepositorio: Sendable { func registrar(_ s: Settlement) async throws -> ResultadoSettle }`
  - `enum ResultadoSettle: Equatable, Sendable { case registrado; case duplicado; case rechazado(razon: String) }`
  - `struct CasosDeUsoSettle { init(repo: SettlementRepositorio, membresia: Membresia); func registrarPago(_:) async throws -> ResultadoSettle; func sugerir(saldos:) -> [Transferencia] }`
  - `struct ComandoRegistrarPago { let tripId, settlementId: String; let from, to: MiembroId; let transferIndex: Int; let amountMinor: Int64; let actor: MiembroId }`

- **Step 1: Write the failing test**

```swift
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Registrar pago (ADR-0016)")
struct CasosDeUsoSettleTests {
    func repo() -> RepositorioEnMemoria { RepositorioEnMemoria() }

    @Test func registraUnPagoDeMiembro() async throws {
        let r = repo()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        await r.anadirMiembro(MiembroId("ivan"), a: "t1")
        let casos = CasosDeUsoSettle(repo: r, membresia: r)
        let res = try await casos.registrarPago(.init(tripId: "t1", settlementId: "s1", from: MiembroId("ivan"), to: MiembroId("ana"), transferIndex: 0, amountMinor: 2000, actor: MiembroId("ivan")))
        #expect(res == .registrado)
    }

    @Test func reintentoMismoSettlementIdEsDuplicado() async throws {
        let r = repo()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        await r.anadirMiembro(MiembroId("ivan"), a: "t1")
        let casos = CasosDeUsoSettle(repo: r, membresia: r)
        let cmd = ComandoRegistrarPago(tripId: "t1", settlementId: "s1", from: MiembroId("ivan"), to: MiembroId("ana"), transferIndex: 0, amountMinor: 2000, actor: MiembroId("ivan"))
        _ = try await casos.registrarPago(cmd)
        let segundo = try await casos.registrarPago(cmd)
        #expect(segundo == .duplicado)
    }

    @Test func noMiembroSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        let casos = CasosDeUsoSettle(repo: r, membresia: r)
        let res = try await casos.registrarPago(.init(tripId: "t1", settlementId: "s1", from: MiembroId("sara"), to: MiembroId("ana"), transferIndex: 0, amountMinor: 2000, actor: MiembroId("sara")))
        #expect(res == .rechazado(razon: "not_member"))
    }

    @Test func importeNoPositivoSeRechaza() async throws {
        let r = repo()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        await r.anadirMiembro(MiembroId("ivan"), a: "t1")
        let casos = CasosDeUsoSettle(repo: r, membresia: r)
        let res = try await casos.registrarPago(.init(tripId: "t1", settlementId: "s1", from: MiembroId("ivan"), to: MiembroId("ana"), transferIndex: 0, amountMinor: 0, actor: MiembroId("ivan")))
        #expect(res == .rechazado(razon: "invalid_amount"))
    }
}
```

- **Step 2: Run test to verify it fails**

Run: `cd packages/TripSquadExpenses && swift test --filter CasosDeUsoSettleTests`
Expected: FAIL — `cannot find 'CasosDeUsoSettle'` / `RepositorioEnMemoria` no conforma `SettlementRepositorio` (Task 3 lo añade; este test compila tras Task 3 pero se ESCRIBE aquí; si SwiftPM bloquea la compilación del módulo entero, hacer Task 2 y 3 en el mismo ciclo rojo→verde).

- **Step 3: Write minimal implementation**

Añadir al final de `Puertos.swift`:

```swift
/// Resultado de registrar un pago (ADR-0016). `duplicado` = mismo settlementId ya
/// registrado (idempotencia estructural, ADR-0015 §5), NO es un error.
public enum ResultadoSettle: Equatable, Sendable {
    case registrado
    case duplicado
    case rechazado(razon: String)
}

/// Puerto de persistencia de pagos. La idempotencia es por la clave estructural del
/// Settlement (settlementId + from||to||transferIndex), no por (actor, key).
public protocol SettlementRepositorio: Sendable {
    func registrar(_ settlement: Settlement) async throws -> ResultadoSettle
}
```

Crear `CasosDeUsoSettle.swift`:

```swift
import TripSquadDomain

public struct ComandoRegistrarPago: Sendable {
    public let tripId: String
    public let settlementId: String
    public let from: MiembroId
    public let to: MiembroId
    public let transferIndex: Int
    public let amountMinor: Int64
    public let actor: MiembroId
    public init(tripId: String, settlementId: String, from: MiembroId, to: MiembroId, transferIndex: Int, amountMinor: Int64, actor: MiembroId) {
        self.tripId = tripId; self.settlementId = settlementId
        self.from = from; self.to = to
        self.transferIndex = transferIndex; self.amountMinor = amountMinor; self.actor = actor
    }
}

/// Casos de uso de `:settle` (ADR-0016). Sugerir es lectura pura; registrar es la
/// escritura idempotente de un pago real.
public struct CasosDeUsoSettle: Sendable {
    private let repo: SettlementRepositorio
    private let membresia: Membresia
    public init(repo: SettlementRepositorio, membresia: Membresia) {
        self.repo = repo; self.membresia = membresia
    }

    /// Concepto (a): sugiere las transferencias que dejan los saldos a cero. Pura.
    public func sugerir(saldos: [MiembroId: Int64]) -> [Transferencia] {
        liquidar(saldos)
    }

    /// Concepto (c): registra un pago real. Idempotente por settlementId.
    public func registrarPago(_ c: ComandoRegistrarPago) async throws -> ResultadoSettle {
        guard try await membresia.esMiembro(c.actor, de: c.tripId) else { return .rechazado(razon: "not_member") }
        if try await membresia.viajeCerrado(c.tripId) { return .rechazado(razon: "trip_closed") }
        guard c.amountMinor > 0 else { return .rechazado(razon: "invalid_amount") }
        let s = Settlement(settlementId: c.settlementId, tripId: c.tripId, from: c.from, to: c.to, transferIndex: c.transferIndex, amountMinor: c.amountMinor)
        return try await repo.registrar(s)
    }
}
```

- **Step 4: Run test (junto con Task 3)**

Run: `cd packages/TripSquadExpenses && swift test --filter CasosDeUsoSettleTests`
Expected: PASS tras completar Task 3 (el repo en-memoria debe conformar el puerto).

- **Step 5: Commit**

```bash
git add packages/TripSquadExpenses/Sources/TripSquadExpenses/Puertos.swift packages/TripSquadExpenses/Sources/TripSquadExpenses/CasosDeUsoSettle.swift packages/TripSquadExpenses/Tests/TripSquadExpensesTests/CasosDeUsoSettleTests.swift
git commit -m "feat(settle): puerto SettlementRepositorio + caso de uso registrarPago"
```

---

### Task 3: `RepositorioEnMemoria` conforma `SettlementRepositorio`

**Files:**
- Modify: `packages/TripSquadExpenses/Sources/TripSquadExpenses/RepositorioEnMemoria.swift`

**Interfaces:**
- Consumes: `Settlement`, `ResultadoSettle`, `SettlementRepositorio` (Task 2).
- Produces: `extension RepositorioEnMemoria: SettlementRepositorio`. Dedupe por `idDeterminista` con un `Set<String>` interno.

- **Step 1: (test cubierto por Task 2)** — los tests de Task 2 son la especificación ejecutable de esta conformidad.

- **Step 2: Añadir el almacén y la conformidad**

En `RepositorioEnMemoria` (dentro del actor), añadir la propiedad:

```swift
    private var settlements: [String: Settlement] = [:]   // idDeterminista -> settlement
```

Y al final del archivo, la conformidad:

```swift
extension RepositorioEnMemoria: SettlementRepositorio {
    /// Dedupe estructural (ADR-0015 §5): la primera vez registra; los reintentos con
    /// la misma clave son `duplicado` (idempotente, no error).
    public func registrar(_ settlement: Settlement) -> ResultadoSettle {
        let clave = settlement.idDeterminista
        if settlements[clave] != nil { return .duplicado }
        settlements[clave] = settlement
        return .registrado
    }
}
```

- **Step 3: Run tests**

Run: `cd packages/TripSquadExpenses && swift test`
Expected: PASS — Task 2 y Task 3 verdes (registra, duplicado, not_member, invalid_amount).

- **Step 4: Commit**

```bash
git add packages/TripSquadExpenses/Sources/TripSquadExpenses/RepositorioEnMemoria.swift
git commit -m "feat(settle): RepositorioEnMemoria conforma SettlementRepositorio (dedupe estructural)"
```

---

### Task 4: Endpoints HTTP — `GET .../settlement/suggestion` y `POST .../settlements`

**Files:**
- Create: `packages/TripSquadService/Sources/TripSquadServiceCore/SettleRoutes.swift`
- Modify: `packages/TripSquadService/Sources/TripSquadServiceCore/Router.swift` (montar las rutas + añadir deps)
- Test: `packages/TripSquadService/Tests/TripSquadServiceTests/SettleRoutesTests.swift`

**Interfaces:**
- Consumes: `CasosDeUsoSettle`, `ContextoAutenticado` (`ctx.actor`), el repo de gastos para calcular saldos vía `balances(...)`.
- Produces: `func montarSettle(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias)`.
- Añadir a `Dependencias`: `let casosSettle: CasosDeUsoSettle`.

**Contrato HTTP:**
- `GET /trips/:tripId/settlement/suggestion` → 200 `{"transfers":[{"from","to","amountMinor"}]}`. Membresía requerida (el middleware ya garantiza auth; la no-membresía → 403 `not_member`). Sin Idempotency-Key.
- `POST /trips/:tripId/settlements` → 201 `{"result":"registered"}` la 1ª vez; 200 `{"result":"duplicate"}` en reintento del mismo `settlementId`; 422 `{"error":{"code":"..."}}` en rechazo permanente (`invalid_amount`, `not_member`, `trip_closed`) en la API directa. Body: `{"settlementId","from","to","transferIndex","amountMinor"}`. El `actor` sale del JWT, no del body.

- **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Endpoints :settle (ADR-0016)")
struct SettleRoutesTests {
    let trip = "trip-1"
    static let clave = ClaveDePrueba(kid: "test")
    func bearer(_ sub: String) async throws -> String { "Bearer \(try await firmar(Self.clave, sub: sub))" }

    func app() async -> (any ApplicationProtocol, RepositorioEnMemoria) {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(MiembroId("ana"), a: trip)
        await repo.anadirMiembro(MiembroId("ivan"), a: trip)
        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        return (Application(router: construirRouter(deps)), repo)
    }

    func pago(id: String, amount: Int64 = 2000) -> ByteBuffer {
        ByteBuffer(string: #"{"settlementId":"\#(id)","from":"ivan","to":"ana","transferIndex":0,"amountMinor":\#(amount)}"#)
    }

    @Test func registrarPago201() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: pago(id: "s1")) { res in
                #expect(res.status == .created)
                #expect(String(buffer: res.body).contains("registered"))
            }
        }
    }

    @Test func reintentoMismoIdEs200Duplicate() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            _ = try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: pago(id: "s1")) { _ in }
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: pago(id: "s1")) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("duplicate"))
            }
        }
    }

    @Test func importeCeroEs422() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlements", method: .post,
                headers: [.authorization: try await bearer("ivan")], body: pago(id: "s1", amount: 0)) { res in
                #expect(res.status.code == 422)
            }
        }
    }

    @Test func sugerenciaGET200() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlement/suggestion", method: .get,
                headers: [.authorization: try await bearer("ana")]) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("transfers"))
            }
        }
    }

    @Test func sugerenciaNoMiembro403() async throws {
        let (app, _) = await app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/trips/\(trip)/settlement/suggestion", method: .get,
                headers: [.authorization: try await bearer("sara")]) { res in
                #expect(res.status == .forbidden)
            }
        }
    }
}
```

- **Step 2: Run test to verify it fails**

Run: `cd packages/TripSquadService && swift test --filter SettleRoutesTests`
Expected: FAIL — `Dependencias` no tiene `casosSettle` / `montarSettle` no existe.

- **Step 3: Write minimal implementation**

En `Router.swift`, añadir a `Dependencias` la propiedad `casosSettle` (y a su `init`), y montar las rutas en el grupo autenticado (junto a `montarGastos`):

```swift
    montarSettle(
        router.group()
            .add(middleware: AuthMiddleware(verificador: deps.verificador, respuesta: respuestaAuthAPI))
            .group(context: ContextoAutenticado.self),
        deps)
```

Crear `SettleRoutes.swift`:

```swift
import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

struct RegistrarPagoDTO: Codable {
    let settlementId: String
    let from: String
    let to: String
    let transferIndex: Int
    let amountMinor: Int64
}

func montarSettle(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // GET sugerencia — lectura pura (ADR-0016 a). Membresía requerida.
    router.get("trips/:tripId/settlement/suggestion") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        guard try await deps.repo.esMiembro(ctx.actor, de: tripId) else {
            return errorJSON(.forbidden, "not_member")
        }
        let gastos = try await deps.repo.gastos(de: tripId).map(\.gasto)
        let saldos = try balances(gastos)
        let transfers = deps.casosSettle.sugerir(saldos: saldos)
        let items = transfers.map { #"{"from":"\#($0.de.raw)","to":"\#($0.a.raw)","amountMinor":\#($0.importeMinor)}"# }
        let body = #"{"transfers":[\#(items.joined(separator: ","))]}"#
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: .init(string: body)))
    }

    // POST registrar pago — escritura idempotente (ADR-0016 c).
    router.post("trips/:tripId/settlements") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: RegistrarPagoDTO.self, context: ctx)
        let r = try await deps.casosSettle.registrarPago(.init(
            tripId: tripId, settlementId: dto.settlementId,
            from: MiembroId(dto.from), to: MiembroId(dto.to),
            transferIndex: dto.transferIndex, amountMinor: dto.amountMinor,
            actor: ctx.actor))
        switch r {
        case .registrado:
            return Response(status: .created, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: .init(string: #"{"result":"registered"}"#)))
        case .duplicado:
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: .init(string: #"{"result":"duplicate"}"#)))
        case .rechazado(let razon):
            return errorJSON(HTTPResponse.Status(code: 422), razon)
        }
    }
}
```

Nota: `errorJSON` ya existe en `GastosRoutes.swift` (mismo módulo). `balances` y `MiembroId` vienen de `TripSquadDomain`. Actualizar TODOS los sitios que construyen `Dependencias` (main.swift + los helper `app()` de RoutesTests) para pasar `casosSettle`.

- **Step 4: Run test to verify it passes**

Run: `cd packages/TripSquadService && swift test`
Expected: PASS — SettleRoutesTests (5) + los tests previos siguen verdes.

- **Step 5: Commit**

```bash
git add packages/TripSquadService/Sources/TripSquadServiceCore/SettleRoutes.swift packages/TripSquadService/Sources/TripSquadServiceCore/Router.swift packages/TripSquadService/Sources/TripSquadService/main.swift packages/TripSquadService/Tests/TripSquadServiceTests/SettleRoutesTests.swift packages/TripSquadService/Tests/TripSquadServiceTests/RoutesTests.swift
git commit -m "feat(settle): endpoints GET suggestion + POST settlements (ADR-0016)"
```

---

### Task 5: Gate G4 (bead 8hn) — dos POST concurrentes con el mismo settlementId = una ejecución

**Files:**
- Modify: `packages/TripSquadService/Tests/TripSquadServiceTests/SettleRoutesTests.swift` (añadir el test de concurrencia)

**Interfaces:**
- Consumes: todo lo anterior. Verifica el invariante de ADR-0015 §5 sobre el endpoint real.

- **Step 1: Write the failing/verifying test**

```swift
    @Test("G4 (8hn): dos POST concurrentes con el mismo settlementId = una registrada")
    func g4_concurrenciaMismoSettlementId() async throws {
        let (app, repo) = await app()
        try await app.test(.router) { client in
            // Lanza N peticiones concurrentes del MISMO settlementId.
            await withTaskGroup(of: Int.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        (try? await client.execute(uri: "/trips/\(self.trip)/settlements", method: .post,
                            headers: [.authorization: try await self.bearer("ivan")], body: self.pago(id: "s-concurrente")) { res in
                            Int(res.status.code)
                        }) ?? 0
                    }
                }
                var registrados201 = 0
                for await code in group where code == 201 { registrados201 += 1 }
                // Exactamente UNA registra (201); el resto son 200 duplicate. Nunca 2 registros.
                #expect(registrados201 == 1, "solo una petición debe registrar; el resto son idempotentes")
            }
        }
        // Y en el almacén hay exactamente 1 settlement con esa clave.
        #expect(await repo.contarSettlements(settlementId: "s-concurrente") == 1)
    }
```

Añadir a `RepositorioEnMemoria` un helper de test:

```swift
    public func contarSettlements(settlementId: String) -> Int {
        settlements.values.filter { $0.settlementId == settlementId }.count
    }
```

- **Step 2: Run test to verify behavior**

Run: `cd packages/TripSquadService && swift test --filter SettleRoutesTests`
Expected: PASS. NOTA: el `RepositorioEnMemoria` es un `actor`, así que las 8 tareas serializan en él — exactamente una ve el `Set` vacío y registra. Este test fija el invariante que el adaptador Postgres deberá replicar con `ON CONFLICT DO NOTHING` (bead futuro de integración Postgres).

- **Step 3: Commit**

```bash
git add packages/TripSquadService/Tests/TripSquadServiceTests/SettleRoutesTests.swift packages/TripSquadExpenses/Sources/TripSquadExpenses/RepositorioEnMemoria.swift
git commit -m "test(settle): G4 concurrencia mismo settlementId = una ejecución (bead 8hn)"
```

---

## Notas de cierre (no son tareas)

- **Postgres real:** el `RepositorioPostgres` NO se toca en este plan (registra pagos en memoria). El adaptador Postgres de settlements (INSERT ... ON CONFLICT DO NOTHING contra la tabla `settlements` existente) + su test de integración G4 contra Postgres real es un bead nuevo a abrir. La tabla ya existe en la migración.
- **Saldos con settlements:** `balances(gastos)` hoy solo mira gastos. Incorporar los pagos registrados al cálculo de saldo neto (un pago de ivan→ana reduce lo que ivan debe) es una mejora a abrir como bead: la sugerencia actual ignora pagos ya hechos. Documentarlo, no silenciarlo.
- **8hn** se cierra con Task 5. **ADR-0016** ya está escrito y debe ir en el mismo PR o uno previo.
