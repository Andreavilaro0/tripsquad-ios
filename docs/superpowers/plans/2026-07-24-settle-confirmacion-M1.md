# `:settle` Confirmación (M1) — Implementation Plan

> **Referencia de diseño — no es un tracker.** El estado de ejecución y su avance viven en beads (bd), nunca en este documento. Los pasos de abajo son el plan de referencia (viñetas), no checkboxes de seguimiento. Ver AGENTS.md, sección Rules.

**Goal:** Convertir la escritura de `:settle` en el flujo pendiente→confirmación de ADR-0017: un miembro (pagador o cobrador) crea una afirmación de pago que la contraparte confirma o rechaza; solo `confirmed` mueve saldos.

**Architecture:** Clean Arch existente (ADR-0009/0010). El dominio (`Settlement` + máquina de estados en `CasosDeUsoSettle`) no conoce HTTP ni SQL. Puerto `SettlementRepositorio` ampliado; adaptadores en-memoria (referencia) y Postgres. Rutas Hummingbird finas que orquestan. Idempotencia estructural por la clave natural del pago (ADR-0015 §5), ahora **incluyendo `tripId`** (fix del hallazgo B de la revisión multi-modelo).

**Tech Stack:** Swift 6.2, Hummingbird 2, PostgresNIO, swift-testing.

## Global Constraints

- **Dinero** siempre `Int64` de céntimos. Nunca floats.
- **Actor** siempre del JWT (`ctx.actor`), jamás del body (ADR-0014).
- **Solo `confirmed` mueve saldos.** `pending`/`rejected`/`cancelled` no afectan a `balances()` ni a la sugerencia (más allá del aviso informativo).
- **Idempotencia:** crear dedup por clave natural `(tripId, settlementId, from, to, transferIndex)` — el importe NO entra. Transiciones idempotentes: repetir la misma transición terminal = mismo resultado, no error.
- **Estados:** `pending → confirmed | rejected | cancelled`. Terminales no re-transicionan.
- **Autorización:** crear → `actor ∈ {from,to}` y `from`,`to` miembros; confirm/reject → la contraparte (parte ≠ creador); cancel → el creador. Todo sobre `pending`.
- **Caducidad:** un `pending` con `expiresAt < now` se trata como `cancelled` (expiración perezosa en lectura; el cron de limpieza es un bead aparte).
- No editar migración `0001` (append-only) → nueva `0002`.
- Fuera de este plan: **notificación/outbox** (necesita diseñar el outbox primero; 8hn queda con su parte de outbox+notif abierta).

---

### Task 1: Modelo de estados + clave natural + migración 0002

**Files:**
- Modify: `packages/TripSquadExpenses/Sources/TripSquadExpenses/Settlement.swift`
- Test: `packages/TripSquadExpenses/Tests/TripSquadExpensesTests/SettlementTests.swift`
- Create: `db/migrations/0002_settlements_confirmacion.sql`

**Interfaces:**
- Produces:
  - `enum EstadoSettlement: String, Sendable, Equatable { case pending, confirmed, rejected, cancelled }`
  - `Settlement` gana: `status: EstadoSettlement`, `createdBy: MiembroId`, `expiresAt: Date`, `resolvedBy: MiembroId?`, `resolvedAt: Date?`, `rejectReason: String?`. Init con valores por defecto (`status: .pending`, `resolved*: nil`).
  - `struct ClaveSettlement: Hashable, Sendable { let tripId, settlementId: String; let from, to: MiembroId; let transferIndex: Int }` y `var Settlement.clave: ClaveSettlement`.
  - Se **elimina** `idDeterminista` (reemplazado por `clave`, que incluye `tripId` y no usa concatenación ambigua — fix B).

- **Step 1: Escribir el test que falla**

Reemplaza el contenido de `SettlementTests.swift`:
```swift
import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Settlement — clave natural y estados")
struct SettlementTests {
    func s(_ trip: String = "t1", _ sid: String = "s1", from: String = "ana", to: String = "ivan", idx: Int = 0) -> Settlement {
        Settlement(settlementId: sid, tripId: trip, from: MiembroId(from), to: MiembroId(to),
                   transferIndex: idx, amountMinor: 2000, createdBy: MiembroId(from),
                   expiresAt: Date(timeIntervalSince1970: 0))
    }

    @Test func naceEnPending() {
        #expect(s().status == .pending)
    }

    @Test func claveIgnoraImporteYEstado() {
        let a = s()
        let b = Settlement(settlementId: "s1", tripId: "t1", from: MiembroId("ana"), to: MiembroId("ivan"),
                           transferIndex: 0, amountMinor: 9999, createdBy: MiembroId("ana"),
                           expiresAt: Date(timeIntervalSince1970: 0))
        #expect(a.clave == b.clave)   // el importe no entra en la clave
    }

    @Test func claveDistinguePorTripId() {
        // Fix B: dos viajes con el mismo settlementId NO colisionan.
        #expect(s("t1").clave != s("t2").clave)
    }

    @Test func claveDistinguePorTransferIndex() {
        #expect(s(idx: 0).clave != s(idx: 1).clave)
    }
}
```

- **Step 2: Ver que falla**

Run: `cd packages/TripSquadExpenses && swift test --filter SettlementTests`
Expected: FAIL — no compila (`status`, `createdBy`, `expiresAt`, `clave` no existen; `idDeterminista` aún referenciado en otros sitios se arregla en Task 2/3).

- **Step 3: Reescribir `Settlement.swift`**
```swift
import Foundation
import TripSquadDomain

/// Estado de una afirmación de pago (ADR-0017). Solo `confirmed` mueve saldos.
public enum EstadoSettlement: String, Sendable, Equatable {
    case pending, confirmed, rejected, cancelled
}

/// Una afirmación de pago entre dos miembros (ADR-0017). Nace `pending`; la contraparte
/// la confirma o rechaza. Append-only: las transiciones no borran, cambian estado.
public struct Settlement: Equatable, Sendable {
    public let settlementId: String   // generado en cliente; parte de la clave natural
    public let tripId: String
    public let from: MiembroId
    public let to: MiembroId
    public let transferIndex: Int
    public let amountMinor: Int64
    public let createdBy: MiembroId   // quién la creó → define la contraparte
    public let expiresAt: Date
    public var status: EstadoSettlement
    public var resolvedBy: MiembroId?
    public var resolvedAt: Date?
    public var rejectReason: String?

    public init(settlementId: String, tripId: String, from: MiembroId, to: MiembroId,
                transferIndex: Int, amountMinor: Int64, createdBy: MiembroId, expiresAt: Date,
                status: EstadoSettlement = .pending, resolvedBy: MiembroId? = nil,
                resolvedAt: Date? = nil, rejectReason: String? = nil) {
        self.settlementId = settlementId; self.tripId = tripId
        self.from = from; self.to = to
        self.transferIndex = transferIndex; self.amountMinor = amountMinor
        self.createdBy = createdBy; self.expiresAt = expiresAt
        self.status = status; self.resolvedBy = resolvedBy
        self.resolvedAt = resolvedAt; self.rejectReason = rejectReason
    }
}

/// Clave natural de dedupe (ADR-0015 §5), AHORA con `tripId` (fix B de la revisión
/// multi-modelo) y sin concatenación ambigua: es un valor estructurado Hashable, no una
/// cadena con separador. El importe NO entra: reintentar el mismo pago con otro importe es
/// el mismo pago.
public struct ClaveSettlement: Hashable, Sendable {
    public let tripId: String
    public let settlementId: String
    public let from: MiembroId
    public let to: MiembroId
    public let transferIndex: Int
}

public extension Settlement {
    var clave: ClaveSettlement {
        ClaveSettlement(tripId: tripId, settlementId: settlementId, from: from, to: to, transferIndex: transferIndex)
    }
}
```

- **Step 4: Migración 0002**

Create `db/migrations/0002_settlements_confirmacion.sql`:
```sql
-- ADR-0017: :settle pasa a pendiente + confirmación. La dedupe estructural se apoya en la
-- UNIQUE (trip_id, settlement_id, from_member, to_member, transfer_index) ya existente en
-- 0001 (que SÍ incluye trip_id), no en el id. El id pasa a ser un surrogate (UUID cliente).
alter table settlements
    add column status       text        not null default 'pending'
        check (status in ('pending','confirmed','rejected','cancelled')),
    add column created_by   text        not null default '',
    add column expires_at   timestamptz not null default now() + interval '30 days',
    add column resolved_by  text,
    add column resolved_at  timestamptz,
    add column reject_reason text;

-- `round` deja de pasarse a mano (fix E): default 0.
alter table settlements alter column round set default 0;
```

- **Step 5: Ver que pasa**

Run: `cd packages/TripSquadExpenses && swift test --filter SettlementTests`
Expected: PASS (4 tests). El resto del módulo aún no compila hasta Task 2 — es esperado; ejecuta solo el filtro.

- **Step 6: Commit**
```bash
git add packages/TripSquadExpenses/Sources/TripSquadExpenses/Settlement.swift \
        packages/TripSquadExpenses/Tests/TripSquadExpensesTests/SettlementTests.swift \
        db/migrations/0002_settlements_confirmacion.sql
git commit -m "feat(settle): modelo de estados + clave natural con tripId (ADR-0017, fix B) + migracion 0002"
```

---

### Task 2: Máquina de estados en el caso de uso + repo en-memoria

**Files:**
- Modify: `packages/TripSquadExpenses/Sources/TripSquadExpenses/Puertos.swift`
- Modify: `packages/TripSquadExpenses/Sources/TripSquadExpenses/CasosDeUsoSettle.swift`
- Modify: `packages/TripSquadExpenses/Sources/TripSquadExpenses/RepositorioEnMemoria.swift`
- Test: `packages/TripSquadExpenses/Tests/TripSquadExpensesTests/CasosDeUsoSettleTests.swift`

**Interfaces:**
- Produces (Puertos.swift):
  - `enum ResultadoSettle: Equatable, Sendable { case creado(id: String); case duplicado(id: String); case rechazado(razon: String) }`
  - `enum ResultadoTransicion: Equatable, Sendable { case ok; case noAutorizado; case noEncontrado; case estadoInvalido; case caducado }`
  - `protocol SettlementRepositorio: Sendable {`
    - `func crear(_ s: Settlement) async throws -> ResultadoSettle`
    - `func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement, por actor: MiembroId, ahora: Date, rejectReason: String?) async throws -> ResultadoTransicion`
    - `func confirmados(de tripId: String) async throws -> [Settlement]`
    - `func pendientes(de tripId: String) async throws -> [Settlement]`
    - `}`
- Produces (CasosDeUsoSettle):
  - `struct ComandoCrearPago: Sendable { tripId, settlementId: String; from, to: MiembroId; transferIndex: Int; amountMinor: Int64; actor: MiembroId }`
  - `func crearPagos(_ cmds: [ComandoCrearPago], ahora: Date) async throws -> [ResultadoSettle]` (lote; valida por item)
  - `func confirmar/rechazar/cancelar(id:en:por:ahora:rejectReason:) async throws -> ResultadoTransicion`
  - `func puedeSugerir(...)` y `func sugerir(...)` se conservan de M0.
- Consumes: `Membresia` (esMiembro/viajeCerrado), `EstadoSettlement`, `Settlement`, `ClaveSettlement`.

- **Step 1: Escribir los tests que fallan**

Reemplaza `CasosDeUsoSettleTests.swift`:
```swift
import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Máquina de estados de :settle (ADR-0017)")
struct CasosDeUsoSettleTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func setup() async -> (RepositorioEnMemoria, CasosDeUsoSettle) {
        let r = RepositorioEnMemoria()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        await r.anadirMiembro(MiembroId("ivan"), a: "t1")
        return (r, CasosDeUsoSettle(repo: r, membresia: r))
    }
    func cmd(_ sid: String = "s1", from: String = "ivan", to: String = "ana",
             amount: Int64 = 2000, actor: String = "ivan") -> ComandoCrearPago {
        .init(tripId: "t1", settlementId: sid, from: MiembroId(from), to: MiembroId(to),
              transferIndex: 0, amountMinor: amount, actor: MiembroId(actor))
    }

    @Test func crearNacePendingYDaId() async throws {
        let (_, casos) = await setup()
        let res = try await casos.crearPagos([cmd()], ahora: t0)
        guard case .creado(let id) = res[0] else { Issue.record("esperaba creado"); return }
        #expect(!id.isEmpty)
    }

    @Test func crearReintentoMismaClaveEsDuplicado() async throws {
        let (_, casos) = await setup()
        _ = try await casos.crearPagos([cmd()], ahora: t0)
        let res = try await casos.crearPagos([cmd(amount: 5)], ahora: t0)  // otro importe, misma clave
        guard case .duplicado = res[0] else { Issue.record("esperaba duplicado"); return }
    }

    @Test func crearActorNoEsParteSeRechaza() async throws {
        let (r, casos) = await setup()
        await r.anadirMiembro(MiembroId("sara"), a: "t1")
        let res = try await casos.crearPagos([cmd(actor: "sara")], ahora: t0)  // sara ∉ {ivan,ana}
        #expect(res[0] == .rechazado(razon: "actor_not_party"))
    }

    @Test func crearParteNoMiembroSeRechaza() async throws {
        let (_, casos) = await setup()
        let res = try await casos.crearPagos([cmd(to: "nadie")], ahora: t0)  // 'nadie' no es miembro
        #expect(res[0] == .rechazado(razon: "payee_not_member"))
    }

    @Test func importeNoPositivoSeRechaza() async throws {
        let (_, casos) = await setup()
        #expect(try await casos.crearPagos([cmd(amount: 0)], ahora: t0)[0] == .rechazado(razon: "invalid_amount"))
    }

    @Test func contraparteConfirma() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        // ivan creó; ana (contraparte) confirma
        let r = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0)
        #expect(r == .ok)
    }

    @Test func creadorNoPuedeConfirmar() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        let r = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ivan"), ahora: t0)  // ivan = creador
        #expect(r == .noAutorizado)
    }

    @Test func creadorCancela() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        #expect(try await casos.cancelar(id: id, en: "t1", por: MiembroId("ivan"), ahora: t0) == .ok)
    }

    @Test func confirmarDosVecesEsIdempotenteNoError() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        _ = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0)
        // repetir la MISMA transición terminal → estadoInvalido (ya no es pending) NO es crash
        #expect(try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0) == .estadoInvalido)
    }

    @Test func rechazarConMotivo() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        #expect(try await casos.rechazar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0, motivo: "no recibí eso") == .ok)
    }

    @Test func pendingCaducadoNoSePuedeConfirmar() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        let futuro = t0.addingTimeInterval(31 * 24 * 3600)   // > 30 días
        #expect(try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: futuro) == .caducado)
    }

    @Test func soloConfirmadosCuentanParaSaldos() async throws {
        let (r, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        #expect(try await r.confirmados(de: "t1").isEmpty)     // pending no cuenta
        _ = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0)
        #expect(try await r.confirmados(de: "t1").count == 1)  // confirmed sí
    }
}
```

- **Step 2: Ver que falla**

Run: `cd packages/TripSquadExpenses && swift test`
Expected: FAIL — no compila (tipos/métodos nuevos no existen; el `registrar` viejo del repo se reemplaza).

- **Step 3: Puertos.swift — reemplazar el puerto de settle**

Sustituye el bloque `ResultadoSettle` + `SettlementRepositorio` de M0 por:
```swift
/// Resultado de CREAR una afirmación de pago (ADR-0017).
public enum ResultadoSettle: Equatable, Sendable {
    case creado(id: String)
    case duplicado(id: String)
    case rechazado(razon: String)
}

/// Resultado de una transición (confirm/reject/cancel).
public enum ResultadoTransicion: Equatable, Sendable {
    case ok
    case noAutorizado    // el actor no puede hacer esta transición
    case noEncontrado
    case estadoInvalido  // no está en `pending`
    case caducado        // pending vencido (expiresAt < ahora)
}

public protocol SettlementRepositorio: Sendable {
    /// Crea si la clave natural (tripId+settlementId+from+to+transferIndex) es nueva;
    /// si ya existe → `duplicado` con el id existente (dedupe ADR-0015 §5).
    func crear(_ settlement: Settlement) async throws -> ResultadoSettle
    /// Transición autorizada de `pending` a un estado terminal. La autorización (quién puede)
    /// la decide el CASO DE USO; el repo solo aplica sobre `pending` no caducado.
    func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement,
                      por actor: MiembroId, ahora: Date, rejectReason: String?) async throws -> ResultadoTransicion
    func confirmados(de tripId: String) async throws -> [Settlement]
    func pendientes(de tripId: String) async throws -> [Settlement]
    /// Lee un settlement por id (para autorizar la transición en el caso de uso).
    func settlement(id: String, en tripId: String) async throws -> Settlement?
}
```
> Nota: añade también `func settlement(id:en:)` al protocolo (usado por el caso de uso para saber quién es la contraparte antes de transicionar).

- **Step 4: CasosDeUsoSettle.swift — la máquina de estados**

Reemplaza `ComandoRegistrarPago`/`registrarPago` por:
```swift
public struct ComandoCrearPago: Sendable {
    public let tripId: String
    public let settlementId: String
    public let from: MiembroId
    public let to: MiembroId
    public let transferIndex: Int
    public let amountMinor: Int64
    public let actor: MiembroId
    public init(tripId: String, settlementId: String, from: MiembroId, to: MiembroId,
                transferIndex: Int, amountMinor: Int64, actor: MiembroId) {
        self.tripId = tripId; self.settlementId = settlementId; self.from = from; self.to = to
        self.transferIndex = transferIndex; self.amountMinor = amountMinor; self.actor = actor
    }
}
```
Y dentro de `CasosDeUsoSettle` (conserva `puedeSugerir` y `sugerir` de M0), añade:
```swift
    private static let ttl: TimeInterval = 30 * 24 * 3600   // 30 días (ADR-0017)

    /// Crea afirmaciones en lote (ADR-0017). Valida por item; un item inválido no tumba el
    /// resto. `actor` debe ser parte del pago y `from`/`to` miembros del viaje (fix C).
    public func crearPagos(_ cmds: [ComandoCrearPago], ahora: Date) async throws -> [ResultadoSettle] {
        var out: [ResultadoSettle] = []
        for c in cmds {
            out.append(try await crearUno(c, ahora: ahora))
        }
        return out
    }

    private func crearUno(_ c: ComandoCrearPago, ahora: Date) async throws -> ResultadoSettle {
        guard c.actor == c.from || c.actor == c.to else { return .rechazado(razon: "actor_not_party") }
        guard try await membresia.esMiembro(c.from, de: c.tripId),
              try await membresia.esMiembro(c.to, de: c.tripId) else { return .rechazado(razon: "payee_not_member") }
        if try await membresia.viajeCerrado(c.tripId) { return .rechazado(razon: "trip_closed") }
        guard c.amountMinor > 0 else { return .rechazado(razon: "invalid_amount") }
        let s = Settlement(settlementId: c.settlementId, tripId: c.tripId, from: c.from, to: c.to,
                           transferIndex: c.transferIndex, amountMinor: c.amountMinor,
                           createdBy: c.actor, expiresAt: ahora.addingTimeInterval(Self.ttl))
        return try await repo.crear(s)
    }

    public func confirmar(id: String, en tripId: String, por actor: MiembroId, ahora: Date) async throws -> ResultadoTransicion {
        try await transicion(id: id, en: tripId, a: .confirmed, por: actor, ahora: ahora, esCreador: false, motivo: nil)
    }
    public func rechazar(id: String, en tripId: String, por actor: MiembroId, ahora: Date, motivo: String?) async throws -> ResultadoTransicion {
        try await transicion(id: id, en: tripId, a: .rejected, por: actor, ahora: ahora, esCreador: false, motivo: motivo)
    }
    public func cancelar(id: String, en tripId: String, por actor: MiembroId, ahora: Date) async throws -> ResultadoTransicion {
        try await transicion(id: id, en: tripId, a: .cancelled, por: actor, ahora: ahora, esCreador: true, motivo: nil)
    }

    /// Autoriza según quién puede: confirm/reject → la CONTRAPARTE (parte ≠ createdBy);
    /// cancel → el CREADOR. Luego delega la aplicación (sobre pending no caducado) al repo.
    private func transicion(id: String, en tripId: String, a nuevo: EstadoSettlement,
                            por actor: MiembroId, ahora: Date, esCreador: Bool, motivo: String?) async throws -> ResultadoTransicion {
        guard let s = try await repo.settlement(id: id, en: tripId) else { return .noEncontrado }
        let contraparte = (s.createdBy == s.from) ? s.to : s.from
        let autorizado = esCreador ? (actor == s.createdBy) : (actor == contraparte)
        guard autorizado else { return .noAutorizado }
        return try await repo.transicionar(id: id, en: tripId, a: nuevo, por: actor, ahora: ahora, rejectReason: motivo)
    }
```

- **Step 5: RepositorioEnMemoria.swift — implementar el puerto nuevo**

Sustituye la extensión `SettlementRepositorio` de M0 por (el almacén pasa a indexar por `id`, con un índice de clave natural para el dedupe):
```swift
extension RepositorioEnMemoria: SettlementRepositorio {
    public func crear(_ settlement: Settlement) -> ResultadoSettle {
        if let existente = settlements.values.first(where: { $0.clave == settlement.clave }) {
            return .duplicado(id: existente.id)
        }
        let id = nuevoIdSettlement()
        settlementsPorId[id] = settlement
        settlements[id] = settlement   // reutiliza el dict existente como almacén por id
        return .creado(id: id)
    }
    public func settlement(id: String, en tripId: String) -> Settlement? {
        settlements[id].flatMap { $0.tripId == tripId ? $0 : nil }
    }
    public func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement,
                             por actor: MiembroId, ahora: Date, rejectReason: String?) -> ResultadoTransicion {
        guard var s = settlements[id], s.tripId == tripId else { return .noEncontrado }
        if s.status == .pending && s.expiresAt < ahora { return .caducado }
        guard s.status == .pending else { return .estadoInvalido }
        s.status = nuevo; s.resolvedBy = actor; s.resolvedAt = ahora; s.rejectReason = rejectReason
        settlements[id] = s
        return .ok
    }
    public func confirmados(de tripId: String) -> [Settlement] {
        settlements.values.filter { $0.tripId == tripId && $0.status == .confirmed }
    }
    public func pendientes(de tripId: String) -> [Settlement] {
        settlements.values.filter { $0.tripId == tripId && $0.status == .pending && $0.expiresAt >= ultimoAhora }
    }
}
```
Ajusta el almacén: cambia `private var settlements: [String: Settlement]` (que en M0 indexaba por idDeterminista) a indexar por `id` generado; añade `private var contadorSettlement = 0` y:
```swift
    private func nuevoIdSettlement() -> String { contadorSettlement += 1; return "set-\(contadorSettlement)" }
```
> `pendientes` usa `ultimoAhora`: como el repo en-memoria no tiene reloj, filtra con el `expiresAt` sin comparar tiempo (para el test basta contar pending); simplifica a `$0.status == .pending`. (Quita `ultimoAhora`.)

Corrección: la versión final de `pendientes`:
```swift
    public func pendientes(de tripId: String) -> [Settlement] {
        settlements.values.filter { $0.tripId == tripId && $0.status == .pending }
    }
```
Y borra la línea `settlementsPorId` (usa solo `settlements` indexado por id).

- **Step 6: Ver que pasa**

Run: `cd packages/TripSquadExpenses && swift test`
Expected: PASS — SettlementTests (4) + CasosDeUsoSettleTests (12) + los tests de gastos previos.

- **Step 7: Commit**
```bash
git add packages/TripSquadExpenses/Sources/TripSquadExpenses/Puertos.swift \
        packages/TripSquadExpenses/Sources/TripSquadExpenses/CasosDeUsoSettle.swift \
        packages/TripSquadExpenses/Sources/TripSquadExpenses/RepositorioEnMemoria.swift \
        packages/TripSquadExpenses/Tests/TripSquadExpensesTests/CasosDeUsoSettleTests.swift
git commit -m "feat(settle): maquina de estados pending/confirm/reject/cancel + autorizacion partes (ADR-0017, fix C)"
```

---

### Task 3: Adaptador Postgres + test de integración (cierra la parte DB de 8hn)

**Files:**
- Modify: `packages/TripSquadExpensesPostgres/Sources/TripSquadExpensesPostgres/RepositorioPostgres.swift`
- Test: `packages/TripSquadExpensesPostgres/Tests/TripSquadExpensesPostgresTests/SettlementPostgresTests.swift` (nuevo; patrón de los tests de integración existentes con `PG_TEST=1`)

**Interfaces:** implementa el mismo `SettlementRepositorio` de Task 2 contra Postgres.

- **Step 1: Test de integración (se salta sin BD, corre en CI con PG_TEST=1)**

Mira primero un test de integración existente para copiar el arranque de conexión:
`grep -n "PG_TEST\|withConnection\|func haciaBD\|RepositorioPostgres(" packages/TripSquadExpensesPostgres/Tests/ -r`. Reusa ese helper. El test:
```swift
// Requiere PG_TEST=1 y una BD con las migraciones 0001+0002 aplicadas.
@Test func crearEsIdempotentePorClaveNatural() async throws {
    try await conBD { repo, tripId in
        let s = Settlement(settlementId: "s1", tripId: tripId, from: MiembroId("ivan"), to: MiembroId("ana"),
                           transferIndex: 0, amountMinor: 2000, createdBy: MiembroId("ivan"),
                           expiresAt: Date().addingTimeInterval(3600))
        guard case .creado = try await repo.crear(s) else { Issue.record("1a vez debe crear"); return }
        guard case .duplicado = try await repo.crear(s) else { Issue.record("2a vez debe deduplicar"); return }
    }
}

@Test func confirmarSoloContraparteYCuentaSaldos() async throws {
    try await conBD { repo, tripId in
        let s = Settlement(settlementId: "s2", tripId: tripId, from: MiembroId("ivan"), to: MiembroId("ana"),
                           transferIndex: 0, amountMinor: 2000, createdBy: MiembroId("ivan"),
                           expiresAt: Date().addingTimeInterval(3600))
        guard case .creado(let id) = try await repo.crear(s) else { return }
        #expect(try await repo.confirmados(de: tripId).isEmpty)
        #expect(try await repo.transicionar(id: id, en: tripId, a: .confirmed, por: MiembroId("ana"),
                                            ahora: Date(), rejectReason: nil) == .ok)
        #expect(try await repo.confirmados(de: tripId).count == 1)
    }
}
```
> `conBD(_:)` es el helper de integración a reutilizar/crear: abre conexión, crea un trip + miembros ivan/ana, ejecuta el bloque, limpia. Sigue el patrón de los tests Postgres de gastos.

- **Step 2: Ver que falla** (en CI con BD, o local con `PG_TEST=1` y Docker): FAIL — métodos no implementados.

- **Step 3: Implementar en RepositorioPostgres.swift**

Sustituye la extensión `SettlementRepositorio` de M0 por:
```swift
extension RepositorioPostgres: SettlementRepositorio {
    public func crear(_ s: Settlement) async throws -> ResultadoSettle {
        let id = UUID().uuidString
        // Dedupe por la UNIQUE natural (incluye trip_id). Si choca, no inserta y devolvemos
        // el id existente leyéndolo aparte.
        let ins = try await client.query("""
            INSERT INTO settlements
                (id, trip_id, settlement_id, from_member, to_member, transfer_index, amount_minor, status, created_by, expires_at)
            VALUES (\(id), \(s.tripId), \(s.settlementId), \(s.from.raw), \(s.to.raw), \(s.transferIndex),
                    \(s.amountMinor), 'pending', \(s.createdBy.raw), \(s.expiresAt))
            ON CONFLICT (trip_id, settlement_id, from_member, to_member, transfer_index) DO NOTHING
            RETURNING id
            """, logger: logger)
        for try await (nuevoId) in ins.decode(String.self) { return .creado(id: nuevoId) }
        // Choque: leer el id existente.
        let sel = try await client.query("""
            SELECT id FROM settlements
            WHERE trip_id = \(s.tripId) AND settlement_id = \(s.settlementId)
              AND from_member = \(s.from.raw) AND to_member = \(s.to.raw) AND transfer_index = \(s.transferIndex)
            """, logger: logger)
        for try await (existente) in sel.decode(String.self) { return .duplicado(id: existente) }
        return .duplicado(id: id)   // inalcanzable salvo carrera; el ON CONFLICT ya cubrió
    }

    public func settlement(id: String, en tripId: String) async throws -> Settlement? {
        let rows = try await client.query("""
            SELECT settlement_id, from_member, to_member, transfer_index, amount_minor, created_by,
                   expires_at, status, resolved_by, resolved_at, reject_reason
            FROM settlements WHERE id = \(id) AND trip_id = \(tripId)
            """, logger: logger)
        for try await (sid, fromM, toM, idx, amount, createdBy, expires, status, rBy, rAt, reason)
            in rows.decode((String, String, String, Int, Int64, String, Date, String, String?, Date?, String?).self) {
            return Settlement(settlementId: sid, tripId: tripId, from: MiembroId(fromM), to: MiembroId(toM),
                              transferIndex: idx, amountMinor: amount, createdBy: MiembroId(createdBy),
                              expiresAt: expires, status: EstadoSettlement(rawValue: status) ?? .pending,
                              resolvedBy: rBy.map(MiembroId.init), resolvedAt: rAt, rejectReason: reason)
        }
        return nil
    }

    public func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement,
                             por actor: MiembroId, ahora: Date, rejectReason: String?) async throws -> ResultadoTransicion {
        // UPDATE condicional atómico: solo si sigue 'pending' y no caducado.
        let rows = try await client.query("""
            UPDATE settlements
            SET status = \(nuevo.rawValue), resolved_by = \(actor.raw), resolved_at = \(ahora), reject_reason = \(rejectReason)
            WHERE id = \(id) AND trip_id = \(tripId) AND status = 'pending' AND expires_at >= \(ahora)
            RETURNING id
            """, logger: logger)
        for try await _ in rows.decode(String.self) { return .ok }
        // No actualizó: distinguir por qué.
        guard let s = try await settlement(id: id, en: tripId) else { return .noEncontrado }
        if s.status == .pending && s.expiresAt < ahora { return .caducado }
        return .estadoInvalido
    }

    public func confirmados(de tripId: String) async throws -> [Settlement] { try await porEstado(tripId, "confirmed") }
    public func pendientes(de tripId: String) async throws -> [Settlement] { try await porEstado(tripId, "pending") }

    private func porEstado(_ tripId: String, _ status: String) async throws -> [Settlement] {
        let rows = try await client.query("""
            SELECT id FROM settlements WHERE trip_id = \(tripId) AND status = \(status)
            """, logger: logger)
        var ids: [String] = []
        for try await (idr) in rows.decode(String.self) { ids.append(idr) }
        var out: [Settlement] = []
        for idr in ids { if let s = try await settlement(id: idr, en: tripId) { out.append(s) } }
        return out
    }
}
```

- **Step 4: Ver que pasa** (CI con BD o local `PG_TEST=1`): PASS.
- **Step 5: Commit**
```bash
git add packages/TripSquadExpensesPostgres/
git commit -m "feat(settle): adaptador Postgres del flujo de confirmacion + tests de integracion (cierra DB de 8hn)"
```

---

### Task 4: Los 5 endpoints HTTP + tests

**Files:**
- Modify: `packages/TripSquadService/Sources/TripSquadServiceCore/SettleRoutes.swift`
- Modify: `packages/TripSquadService/Sources/TripSquadServiceCore/Router.swift` (si hace falta un reloj inyectable)
- Test: `packages/TripSquadService/Tests/TripSquadServiceTests/SettleRoutesTests.swift`

**Interfaces:** consume `CasosDeUsoSettle` (Task 2). Reloj: inyectar `deps.ahora: @Sendable () -> Date` (default `Date.init`) para poder testear caducidad de forma determinista.

**Contrato (recuerda ADR-0017 + scope):**
- `POST /trips/:tripId/settlements` (lote) → 201 `{"created":[{"id","status"}|{"status":"duplicate","id"}|{"error":{"code"}}]}` por item; 403 si no-miembro del viaje.
- `POST /trips/:tripId/settlements/:id/confirm` → 200 `{"status":"confirmed"}` · 403 · 409 (estado/caducado) · 404.
- `POST .../:id/reject` (body `{"reason"?}`) → 200 · 403 · 409 · 404.
- `POST .../:id/cancel` → 200 · 403 · 409 · 404.
- `GET /trips/:tripId/settlements?status=pending` → 200 `{"settlements":[…]}`.

- **Step 1..N (TDD):** un test por ruta/estado (201 lote, 200 duplicate, 422 item inválido, 403 no-parte, confirm 200 por contraparte, confirm 403 por creador, 409 al reconfirmar, reject con reason, cancel, list pending). Implementar `montarSettle` con las 5 rutas, `actor = ctx.actor`, DTOs `Encodable`/`Decodable` serializados con `JSONEncoder`/`req.decode` (NUNCA interpolación a mano — finding A). Mapear `ResultadoTransicion`: `.ok→200`, `.noAutorizado→403`, `.noEncontrado→404`, `.estadoInvalido/.caducado→409`.
- **Commit:** `feat(settle): endpoints crear-lote/confirm/reject/cancel/list (ADR-0017)`

> Esta tarea se detalla a nivel de código en su propio brief al ejecutarla (subagent-driven-development), calcando el patrón de `montarGastos`/`SettleRoutes` ya en el repo. Se deja como una tarea porque es un único deliverable testable (la superficie HTTP del flujo).

---

### Task 5: Balances ↔ confirmados + aviso de pendientes (cierra xsx)

**Files:**
- Modify: `packages/TripSquadDomain/Sources/TripSquadDomain/Saldos.swift` (o donde viva `balances`) — nueva función que resta settlements confirmados.
- Modify: `SettleRoutes.swift` (GET suggestion incorpora confirmados + marca pendientes).
- Test: dominio + servicio.

**Interfaces:**
- `func balancesConLiquidaciones(_ gastos: [Gasto], confirmados: [Settlement]) throws -> [MiembroId: Int64]` — parte de `balances(gastos)` y aplica cada pago confirmado (resta al `from`, suma al `to`, o el signo que corresponda al convenio del motor).
- `GET suggestion` usa `balancesConLiquidaciones(gastos, confirmados)` y añade, por transferencia sugerida, `"pending": true` si existe un `pending` que la cubre (par from→to).

- **Step 1: test de dominio** — un gasto que deja a Iván debiendo 2000 a Ana + un settlement confirmado de 2000 ivan→ana ⇒ saldo neto 0 ⇒ sugerencia vacía. Un settlement `pending` NO cambia el saldo.
- **Step 2..4:** implementar, GET marca pendientes, tests de servicio.
- **Commit:** `feat(settle): balances descuenta pagos confirmados + aviso de pendientes (cierra xsx)`

---

### Task 6: Caducidad perezosa (30d) + bead de cron

**Files:**
- Ya cubierta en Tasks 2/3 (transición devuelve `.caducado` si `expiresAt < ahora`; `pendientes` puede excluir vencidos).
- Este task solo añade: (a) test de servicio de caducidad usando el reloj inyectable; (b) crear un **bead** para el cron de limpieza (`UPDATE ... SET status='cancelled' WHERE status='pending' AND expires_at < now()`), que encaja con la infra de cron/pinger existente.

- **Step 1:** test de servicio: crear pending, avanzar el reloj +31d, confirmar → 409 caducado.
- **Step 2:** `bd create` del cron de caducidad (P2).
- **Commit:** `test(settle): caducidad perezosa a 30 dias + bead del cron de limpieza`

---

## Notas de cierre (no son tareas)
- **Fuera de M1:** la **notificación/outbox** (crear→contraparte, resolver→creador). Necesita diseñar el **outbox** primero (no existe). Por eso **8hn** queda con su parte de outbox+notif abierta aunque la de concurrencia/DB se cierre en Task 3.
- **Cierra:** `xsx` (Task 5), la parte DB/concurrencia de `8hn` (Task 3), y los criterios B/C/E/F del bead **649** (B en Task 1, C en Task 2, E en migración 0002, F con los tests de Task 2/3). El criterio **G** (404 vs 403 en viaje inexistente) se resuelve en Task 4 (transición devuelve 404 real).
- Gates por tarea: `swift test` verde + SwiftLint/gitleaks/semgrep + revisión de otro modelo + PR + firma de Andrea.
```
