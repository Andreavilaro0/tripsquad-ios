# Wedge "Quién ya reservó" — Implementation Plan

> **Referencia de diseño — no es un tracker.** El estado de ejecución y su avance viven en beads (bd), nunca en este documento. Los pasos de abajo son el plan de referencia (viñetas), no checkboxes de seguimiento. Ver AGENTS.md, sección Rules.

**Goal:** Dar al viaje un tablero de "quién ya reservó" enganchando un estado de reserva por persona a las actividades del itinerario.

**Architecture:** Módulo nuevo `Reserva` calcado al de `Itinerario`/`Votacion`: tipos puros en `TripSquadExpenses`, autorización en `CasosDeUsoReserva`, puerto `ReservaRepositorio` con doble en memoria + adaptador Postgres, y rutas HTTP en `TripSquadServiceCore`. El estado por-persona del expulsado se limpia en la misma transacción que `quitarMiembro`.

**Tech Stack:** Swift, Hummingbird (HTTP), PostgresNIO, swift-testing (`import Testing`), Clean Architecture (ADR-0009).

## Global Constraints

- Dinero: N/A en este wedge (no toca importes).
- Autorización sin fuga de existencia: `noAutorizado` es el MISMO resultado para "no eres miembro" / "no existe la actividad o la reserva" / "eres miembro pero no puedes tocar esto" (ADR-0018/0019). Nunca se filtra existencia.
- `noAutorizado` → HTTP **403** (`not_member`), consistente con los otros módulos (NO 422 como el bug de Gastos, bead 55x). `viajeCerrado` → 409 (`trip_closed`). `reglaViolada(code)` → 422 con ese code.
- El `actor` SIEMPRE sale de `ctx.actor` (JWT verificado), NUNCA del body.
- Miembro ACTUAL: se usa `membresia.esMiembro` (en Postgres devuelve false si `left_at != null`); un ex-miembro no conserva permisos aunque figure como creador.
- Enums cerrados (`kind`/`estado`): valor no reconocido → 422, nunca crash.
- Tras cada tarea con código: `swift build` + `swift test` del paquete tocado deben pasar antes del commit.

---

## File Structure

- `packages/TripSquadExpenses/Sources/TripSquadExpenses/Reserva.swift` — **crear**. Tipos puros: `Reserva`, `KindReserva`, `ModoReserva`, `EstadoReserva`, `ErrorReserva`.
- `packages/TripSquadExpenses/Sources/TripSquadExpenses/Puertos.swift` — **modificar**. Añadir el protocolo `ReservaRepositorio`.
- `packages/TripSquadExpenses/Sources/TripSquadExpenses/RepositorioEnMemoria.swift` — **modificar**. Implementar `ReservaRepositorio` + limpiar estado del expulsado dentro de `quitarMiembro`.
- `packages/TripSquadExpenses/Sources/TripSquadExpenses/CasosDeUsoReserva.swift` — **crear**. Autorización + reglas.
- `packages/TripSquadExpensesPostgres/Sources/TripSquadExpensesPostgres/RepositorioReservaPostgres.swift` — **crear**. Adaptador Postgres.
- `packages/TripSquadExpensesPostgres/Sources/TripSquadExpensesPostgres/RepositorioViajePostgres.swift:203` — **modificar** `quitarMiembro` para borrar el estado del expulsado en la misma transacción.
- `db/migrations/0008_reservas.sql` — **crear**. Tablas `itinerary_reservations` + `itinerary_reservation_members`.
- `packages/TripSquadService/Sources/TripSquadServiceCore/ReservaRoutes.swift` — **crear**. Rutas + DTOs + mapeo de error.
- `packages/TripSquadService/Sources/TripSquadServiceCore/Router.swift` + `Dependencias` (en `main.swift` / donde se construyan) — **modificar**. Registrar `casosReserva` y `montarReservas`.
- `docs/decisions/00XX-reservas-por-persona.md` — **crear** ADR (siguiente número libre; verificar en `docs/decisions/`, ojo que 0019–0022 están referenciados como borrador en el código).

**Templates a calcar** (leerlos antes de cada tarea):
- Caso de uso → `CasosDeUsoItinerario.swift`.
- Rutas → `ItinerarioRoutes.swift`.
- Adaptador Postgres → `RepositorioItinerarioPostgres.swift`; migración → `db/migrations/0005_itinerario.sql`.
- Tests → `CasosDeUsoItinerarioTests.swift`, `ItinerarioRoutesTests.swift`, `RepositorioItinerarioPostgresTests.swift`.

---

## Task 1: Tipos de dominio + puerto + doble en memoria

**Files:**
- Create: `packages/TripSquadExpenses/Sources/TripSquadExpenses/Reserva.swift`
- Modify: `packages/TripSquadExpenses/Sources/TripSquadExpenses/Puertos.swift`
- Modify: `packages/TripSquadExpenses/Sources/TripSquadExpenses/RepositorioEnMemoria.swift`
- Test: `packages/TripSquadExpenses/Tests/TripSquadExpensesTests/RepositorioReservaEnMemoriaTests.swift`

**Interfaces:**
- Produces (tipos):
```swift
public enum KindReserva: String, Sendable, Equatable, CaseIterable {
    case vuelo, hotel, coche, tren, seguro, otro
}
public enum EstadoReserva: String, Sendable, Equatable {
    case pendiente, reservado
}
public enum ModoReserva: Equatable, Sendable {
    /// Estados SOLO de los miembros incluidos (subconjunto elegido al crear).
    case cadaUnoElSuyo(estados: [MiembroId: EstadoReserva])
    /// Un responsable (nil = sin asignar) + un estado único.
    case unoParaTodos(responsable: MiembroId?, estado: EstadoReserva)
}
public struct Reserva: Equatable, Sendable {
    public let activityId: String
    public let tripId: String
    public let kind: KindReserva
    public let mode: ModoReserva
    public init(activityId: String, tripId: String, kind: KindReserva, mode: ModoReserva)
}
public enum ErrorReserva: Error, Equatable, Sendable {
    case noAutorizado
    case viajeCerrado
    case reglaViolada(String)
}
```
- Produces (puerto):
```swift
public protocol ReservaRepositorio: Sendable {
    /// Crea o REEMPLAZA el aspecto reserva de una actividad (reemplaza participantes/responsable).
    func upsert(_ r: Reserva, ahora: Date) async throws
    func reserva(activityId: String, en tripId: String) async throws -> Reserva?
    /// El tablero: todas las reservas del viaje. Sin tope (nº actividades ya acotado por el itinerario).
    /// Orden estable por `activityId`.
    func tablero(_ tripId: String) async throws -> [Reserva]
    /// Fija el estado de UN miembro (cadaUnoElSuyo, `miembro` no-nil) o del estado único
    /// (unoParaTodos, `miembro == nil`). No valida autorización (eso es del caso de uso).
    func marcarEstado(activityId: String, en tripId: String, miembro: MiembroId?, estado: EstadoReserva) async throws
    func borrar(activityId: String, en tripId: String) async throws
}
```

- **Step 1: Escribe `Reserva.swift`** con los tipos de arriba (copia las firmas del bloque Interfaces, con `import TripSquadDomain` para `MiembroId`). Añade cabecera-comentario al estilo de `Itinerario.swift` (qué es, y que la autorización vive en `CasosDeUsoReserva`).

- **Step 2: Añade `ReservaRepositorio` a `Puertos.swift`** (el bloque de arriba), junto a `ItinerarioRepositorio`, con el mismo estilo de comentario.

- **Step 3: Escribe el test que falla** (el doble en memoria aún no implementa el puerto):

```swift
import Testing
import Foundation
import TripSquadDomain
@testable import TripSquadExpenses

@Suite struct RepositorioReservaEnMemoriaTests {
    let a = MiembroId("a"), b = MiembroId("b")
    func repo() -> RepositorioEnMemoria { RepositorioEnMemoria() }

    @Test func upsertYLeeCadaUnoElSuyo() async throws {
        let r = repo()
        let res = Reserva(activityId: "act1", tripId: "t1", kind: .vuelo,
                          mode: .cadaUnoElSuyo(estados: [a: .pendiente, b: .pendiente]))
        try await r.upsert(res, ahora: Date())
        let leido = try await r.reserva(activityId: "act1", en: "t1")
        #expect(leido == res)
    }

    @Test func marcarEstadoDeUnMiembro() async throws {
        let r = repo()
        try await r.upsert(Reserva(activityId: "act1", tripId: "t1", kind: .vuelo,
            mode: .cadaUnoElSuyo(estados: [a: .pendiente, b: .pendiente])), ahora: Date())
        try await r.marcarEstado(activityId: "act1", en: "t1", miembro: a, estado: .reservado)
        let leido = try await r.reserva(activityId: "act1", en: "t1")
        #expect(leido?.mode == .cadaUnoElSuyo(estados: [a: .reservado, b: .pendiente]))
    }

    @Test func tableroDevuelveTodasOrdenadas() async throws {
        let r = repo()
        try await r.upsert(Reserva(activityId: "act2", tripId: "t1", kind: .hotel,
            mode: .unoParaTodos(responsable: a, estado: .pendiente)), ahora: Date())
        try await r.upsert(Reserva(activityId: "act1", tripId: "t1", kind: .vuelo,
            mode: .cadaUnoElSuyo(estados: [a: .pendiente])), ahora: Date())
        let tablero = try await r.tablero("t1")
        #expect(tablero.map(\.activityId) == ["act1", "act2"])
    }
}
```

- **Step 4: Ejecuta y verifica que falla.**
Run: `swift test --package-path packages/TripSquadExpenses --filter RepositorioReservaEnMemoriaTests`
Expected: FAIL de compilación (`RepositorioEnMemoria` no conforma `ReservaRepositorio`).

- **Step 5: Implementa `ReservaRepositorio` en `RepositorioEnMemoria.swift`.** Añade un almacén `private var reservas: [String: Reserva] = [:]` (clave = `"\(tripId)|\(activityId)"`) protegido por el MISMO mecanismo de aislamiento que usan los otros almacenes del fichero (mira cómo lo hace para itinerario). Implementa:
```swift
func upsert(_ r: Reserva, ahora: Date) async throws { reservas["\(r.tripId)|\(r.activityId)"] = r }
func reserva(activityId: String, en tripId: String) async throws -> Reserva? { reservas["\(tripId)|\(activityId)"] }
func tablero(_ tripId: String) async throws -> [Reserva] {
    reservas.values.filter { $0.tripId == tripId }.sorted { $0.activityId < $1.activityId }
}
func marcarEstado(activityId: String, en tripId: String, miembro: MiembroId?, estado: EstadoReserva) async throws {
    let k = "\(tripId)|\(activityId)"
    guard let r = reservas[k] else { return }
    switch r.mode {
    case .cadaUnoElSuyo(var estados):
        if let m = miembro, estados[m] != nil { estados[m] = estado }
        reservas[k] = Reserva(activityId: r.activityId, tripId: r.tripId, kind: r.kind, mode: .cadaUnoElSuyo(estados: estados))
    case .unoParaTodos(let resp, _):
        reservas[k] = Reserva(activityId: r.activityId, tripId: r.tripId, kind: r.kind, mode: .unoParaTodos(responsable: resp, estado: estado))
    }
}
func borrar(activityId: String, en tripId: String) async throws { reservas["\(tripId)|\(activityId)"] = nil }
```
(Si `RepositorioEnMemoria` es un `actor`, quita los `async` innecesarios según su estilo; si usa un lock, envuelve igual que los demás métodos.)

- **Step 6: Ejecuta y verifica que pasa.**
Run: `swift test --package-path packages/TripSquadExpenses --filter RepositorioReservaEnMemoriaTests`
Expected: PASS (3 tests).

- **Step 7: Commit.**
```bash
git add packages/TripSquadExpenses/Sources/TripSquadExpenses/Reserva.swift \
        packages/TripSquadExpenses/Sources/TripSquadExpenses/Puertos.swift \
        packages/TripSquadExpenses/Sources/TripSquadExpenses/RepositorioEnMemoria.swift \
        packages/TripSquadExpenses/Tests/TripSquadExpensesTests/RepositorioReservaEnMemoriaTests.swift
git commit -m "feat(reserva): tipos de dominio + puerto ReservaRepositorio + doble en memoria"
```

---

## Task 2: Caso de uso `CasosDeUsoReserva` (autorización + reglas)

**Files:**
- Create: `packages/TripSquadExpenses/Sources/TripSquadExpenses/CasosDeUsoReserva.swift`
- Test: `packages/TripSquadExpenses/Tests/TripSquadExpensesTests/CasosDeUsoReservaTests.swift`

**Interfaces:**
- Consumes: `ReservaRepositorio` (Task 1), `ItinerarioRepositorio.item(id:en:)`, `Membresia`, `ViajeRepositorio.rol(de:en:)`, `ViajeRepositorio.miembros(de:)`.
- Produces:
```swift
public struct CasosDeUsoReserva: Sendable {
    public init(repo: ReservaRepositorio, itinerario: ItinerarioRepositorio, membresia: Membresia, viajes: ViajeRepositorio)
    /// Marca una actividad como reservable (crea/edita el aspecto). Creador de la actividad U owner.
    /// `participantes` solo aplica a cadaUnoElSuyo (subconjunto ⊆ miembros); `responsable` solo a unoParaTodos.
    public func definir(tripId: String, activityId: String, kind: KindReserva,
                        modo: ModoDefinicion, actor: MiembroId, ahora: Date) async throws -> Result<Reserva, ErrorReserva>
    /// Quita el aspecto reserva. Creador u owner.
    public func quitar(tripId: String, activityId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorReserva>
    /// Marca estado. cadaUnoElSuyo: `memberId` no-nil, actor == memberId O owner. unoParaTodos:
    /// `memberId == nil`, actor == responsable O owner.
    public func marcar(tripId: String, activityId: String, memberId: MiembroId?, estado: EstadoReserva,
                       actor: MiembroId, ahora: Date) async throws -> Result<Reserva, ErrorReserva>
    /// El tablero. Solo miembros.
    public func tablero(tripId: String, actor: MiembroId) async throws -> Result<[Reserva], ErrorReserva>
}
/// Entrada de `definir`: separa la elección de participantes/responsable de los estados internos.
public enum ModoDefinicion: Equatable, Sendable {
    case cadaUnoElSuyo(participantes: [MiembroId])
    case unoParaTodos(responsable: MiembroId?)
}
```

- **Step 1: Escribe los tests que fallan** (la clase aún no existe). Usa el `RepositorioEnMemoria` como triple (implementa `ReservaRepositorio` + `ItinerarioRepositorio` + `Membresia` + `ViajeRepositorio`; monta un viaje con owner `a` y miembro `b` como en `CasosDeUsoItinerarioTests`). Casos mínimos:

```swift
import Testing
import Foundation
import TripSquadDomain
@testable import TripSquadExpenses

@Suite struct CasosDeUsoReservaTests {
    // Reutiliza el helper de montaje de viaje de CasosDeUsoItinerarioTests:
    // owner = a, miembro = b, y una actividad "act1" creada por b.
    // (copia ese setup; NO lo inventes de cero)

    @Test func definirComoCreadorCreaReservablePendiente() async throws {
        let f = try await fixture()              // owner a, miembro b, actividad act1 creada por b
        let r = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a, f.b]), actor: f.b, ahora: Date())
        #expect(try r.get().mode == .cadaUnoElSuyo(estados: [f.a: .pendiente, f.b: .pendiente]))
    }

    @Test func definirPorNoCreadorNoOwnerEsNoAutorizado() async throws {
        let f = try await fixture()              // c es miembro pero ni creador ni owner
        let r = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a]), actor: f.c, ahora: Date())
        #expect(r == .failure(.noAutorizado))
    }

    @Test func definirConParticipanteNoMiembroEsReglaViolada() async throws {
        let f = try await fixture()
        let r = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [MiembroId("ext")]), actor: f.b, ahora: Date())
        #expect(r == .failure(.reglaViolada("participante_no_miembro")))
    }

    @Test func definirActividadInexistenteEsNoAutorizado() async throws {   // sin fuga de existencia
        let f = try await fixture()
        let r = try await f.casos.definir(tripId: "t1", activityId: "noexiste", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a]), actor: f.a, ahora: Date())
        #expect(r == .failure(.noAutorizado))
    }

    @Test func definirEnViajeCerradoEsViajeCerrado() async throws {
        let f = try await fixture(cerrado: true)
        let r = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a]), actor: f.a, ahora: Date())
        #expect(r == .failure(.viajeCerrado))
    }

    @Test func marcarPropioEstadoOk() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a, f.b]), actor: f.b, ahora: Date())
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.b,
            estado: .reservado, actor: f.b, ahora: Date())
        #expect(try r.get().mode == .cadaUnoElSuyo(estados: [f.a: .pendiente, f.b: .reservado]))
    }

    @Test func marcarEstadoAjenoSinSerOwnerEsNoAutorizado() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a, f.b]), actor: f.b, ahora: Date())
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.a,
            estado: .reservado, actor: f.b, ahora: Date())   // b intenta marcar a a
        #expect(r == .failure(.noAutorizado))
    }

    @Test func ownerPuedeMarcarEstadoAjeno() async throws {
        let f = try await fixture()   // a = owner
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a, f.b]), actor: f.b, ahora: Date())
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.b,
            estado: .reservado, actor: f.a, ahora: Date())   // owner marca a b
        #expect(try r.get().mode == .cadaUnoElSuyo(estados: [f.a: .pendiente, f.b: .reservado]))
    }

    @Test func marcarMiembroNoIncluidoEsReglaViolada() async throws {
        let f = try await fixture()
        _ = try await f.casos.definir(tripId: "t1", activityId: "act1", kind: .vuelo,
            modo: .cadaUnoElSuyo(participantes: [f.a]), actor: f.a, ahora: Date())   // b NO incluido
        let r = try await f.casos.marcar(tripId: "t1", activityId: "act1", memberId: f.b,
            estado: .reservado, actor: f.a, ahora: Date())
        #expect(r == .failure(.reglaViolada("miembro_no_incluido")))
    }

    @Test func tableroSoloMiembros() async throws {
        let f = try await fixture()
        let r = try await f.casos.tablero(tripId: "t1", actor: MiembroId("ext"))
        #expect(r == .failure(.noAutorizado))
    }
}
```

- **Step 2: Ejecuta y verifica que fallan.**
Run: `swift test --package-path packages/TripSquadExpenses --filter CasosDeUsoReservaTests`
Expected: FAIL de compilación (`CasosDeUsoReserva` no existe).

- **Step 3: Implementa `CasosDeUsoReserva.swift`.** Calca el gate de `CasosDeUsoItinerario.editar/borrar`. Lógica clave:

```swift
import Foundation
import TripSquadDomain

public struct CasosDeUsoReserva: Sendable {
    private let repo: ReservaRepositorio
    private let itinerario: ItinerarioRepositorio
    private let membresia: Membresia
    private let viajes: ViajeRepositorio
    public init(repo: ReservaRepositorio, itinerario: ItinerarioRepositorio, membresia: Membresia, viajes: ViajeRepositorio) {
        self.repo = repo; self.itinerario = itinerario; self.membresia = membresia; self.viajes = viajes
    }

    public func definir(tripId: String, activityId: String, kind: KindReserva,
                        modo: ModoDefinicion, actor: MiembroId, ahora: Date) async throws -> Result<Reserva, ErrorReserva> {
        guard let act = try await itinerario.item(id: activityId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        let rol = try await viajes.rol(de: actor, en: tripId)
        guard act.createdBy == actor || rol == .owner else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }

        let miembros = Set(try await viajes.miembros(de: tripId).map { $0.0 })
        let mode: ModoReserva
        switch modo {
        case .cadaUnoElSuyo(let participantes):
            guard !participantes.isEmpty else { return .failure(.reglaViolada("sin_participantes")) }
            guard participantes.allSatisfy({ miembros.contains($0) }) else { return .failure(.reglaViolada("participante_no_miembro")) }
            mode = .cadaUnoElSuyo(estados: Dictionary(uniqueKeysWithValues: participantes.map { ($0, .pendiente) }))
        case .unoParaTodos(let responsable):
            if let resp = responsable, !miembros.contains(resp) { return .failure(.reglaViolada("responsable_no_miembro")) }
            mode = .unoParaTodos(responsable: responsable, estado: .pendiente)
        }
        let reserva = Reserva(activityId: activityId, tripId: tripId, kind: kind, mode: mode)
        try await repo.upsert(reserva, ahora: ahora)
        return .success(reserva)
    }

    public func quitar(tripId: String, activityId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorReserva> {
        guard let act = try await itinerario.item(id: activityId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        let rol = try await viajes.rol(de: actor, en: tripId)
        guard act.createdBy == actor || rol == .owner else { return .failure(.noAutorizado) }
        try await repo.borrar(activityId: activityId, en: tripId)
        return .success(())
    }

    public func marcar(tripId: String, activityId: String, memberId: MiembroId?, estado: EstadoReserva,
                       actor: MiembroId, ahora: Date) async throws -> Result<Reserva, ErrorReserva> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard let reserva = try await repo.reserva(activityId: activityId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }
        let esOwner = (try await viajes.rol(de: actor, en: tripId)) == .owner

        switch reserva.mode {
        case .cadaUnoElSuyo(let estados):
            guard let m = memberId else { return .failure(.reglaViolada("falta_member_id")) }
            guard estados[m] != nil else { return .failure(.reglaViolada("miembro_no_incluido")) }
            guard actor == m || esOwner else { return .failure(.noAutorizado) }
            try await repo.marcarEstado(activityId: activityId, en: tripId, miembro: m, estado: estado)
        case .unoParaTodos(let responsable, _):
            guard memberId == nil else { return .failure(.reglaViolada("member_id_sobra")) }
            guard actor == responsable || esOwner else { return .failure(.noAutorizado) }
            try await repo.marcarEstado(activityId: activityId, en: tripId, miembro: nil, estado: estado)
        }
        guard let actualizada = try await repo.reserva(activityId: activityId, en: tripId) else { return .failure(.noAutorizado) }
        return .success(actualizada)
    }

    public func tablero(tripId: String, actor: MiembroId) async throws -> Result<[Reserva], ErrorReserva> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        return .success(try await repo.tablero(tripId))
    }
}
```

- **Step 4: Ejecuta y verifica que pasan.**
Run: `swift test --package-path packages/TripSquadExpenses --filter CasosDeUsoReservaTests`
Expected: PASS.

- **Step 5: Commit.**
```bash
git add packages/TripSquadExpenses/Sources/TripSquadExpenses/CasosDeUsoReserva.swift \
        packages/TripSquadExpenses/Tests/TripSquadExpensesTests/CasosDeUsoReservaTests.swift
git commit -m "feat(reserva): CasosDeUsoReserva con autorizacion (definir/marcar/quitar/tablero)"
```

---

## Task 3: Rutas HTTP `ReservaRoutes` + wiring

**Files:**
- Create: `packages/TripSquadService/Sources/TripSquadServiceCore/ReservaRoutes.swift`
- Modify: `packages/TripSquadService/Sources/TripSquadServiceCore/Router.swift` (llamar `montarReservas`) y donde se construya `Dependencias` (añadir `casosReserva`).
- Test: `packages/TripSquadService/Tests/TripSquadServiceTests/ReservaRoutesTests.swift`

**Interfaces:**
- Consumes: `CasosDeUsoReserva` (Task 2), `Dependencias`, `ContextoAutenticado` (`ctx.actor`).
- Produces: `func montarReservas(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias)`.

**Endpoints (calca `ItinerarioRoutes.swift`):**
- `PUT /trips/:tripId/itinerary/:activityId/reservation` → `definir`. Body `{ kind, mode, participantes?, responsable? }`.
- `DELETE /trips/:tripId/itinerary/:activityId/reservation` → `quitar`.
- `PUT /trips/:tripId/itinerary/:activityId/reservation/status` → `marcar`. Body `{ memberId?, estado }`.
- `GET /trips/:tripId/reservations` → `tablero`.

- **Step 1: Escribe los tests de ruta que fallan.** Calca `ItinerarioRoutesTests.swift` (mismo helper de app de test + JWT). Casos: PUT reservation por creador → 201/200 con el DTO; PUT status propio → 200; PUT status ajeno sin owner → 403; PUT con `kind` basura → 422; GET /reservations por no-miembro → 403; GET devuelve el tablero. (Escribe el cuerpo real de cada test copiando el estilo de `ItinerarioRoutesTests`; NO dejes placeholders.)

- **Step 2: Ejecuta y verifica que fallan.**
Run: `swift test --package-path packages/TripSquadService --filter ReservaRoutesTests`
Expected: FAIL (no existe `montarReservas`).

- **Step 3: Implementa `ReservaRoutes.swift`.** DTOs de entrada/salida `Decodable`/`Encodable` (nunca JSON a mano — usa `JSONEncoder`, ADR del bead db0). Mapeo de error idéntico a `respuestaErrorItinerario` pero para `ErrorReserva` (`.noAutorizado`→403 `not_member`, `.viajeCerrado`→409 `trip_closed`, `.reglaViolada(code)`→422 `code`). Decodifica `kind`/`estado`/`mode` a los enums; valor no reconocido → 422 `enum_invalido` (no crash). DTO de salida de `Reserva` que serializa el `mode` como `{ tipo: "cadaUnoElSuyo", estados: [{memberId, estado}] }` o `{ tipo: "unoParaTodos", responsable, estado }`.

- **Step 4: Wiring.** En `Dependencias`, añade `let casosReserva: CasosDeUsoReserva` y constrúyelo donde se construyen `casosItinerario` (mismo repo en memoria/Postgres + `membresia` + `viajes`). En `Router.swift`, añade `montarReservas(grupoAutenticado, deps)` junto a `montarItinerario`.

- **Step 5: Ejecuta y verifica que pasan.**
Run: `swift test --package-path packages/TripSquadService --filter ReservaRoutesTests`
Expected: PASS.

- **Step 6: Commit.**
```bash
git add packages/TripSquadService/Sources/TripSquadServiceCore/ReservaRoutes.swift \
        packages/TripSquadService/Sources/TripSquadServiceCore/Router.swift \
        packages/TripSquadService/Sources/TripSquadServiceCore/*.swift \
        packages/TripSquadService/Tests/TripSquadServiceTests/ReservaRoutesTests.swift
git commit -m "feat(reserva): rutas HTTP (definir/marcar/quitar/tablero) + wiring"
```

---

## Task 4: Adaptador Postgres + migración

**Files:**
- Create: `db/migrations/0008_reservas.sql`
- Create: `packages/TripSquadExpensesPostgres/Sources/TripSquadExpensesPostgres/RepositorioReservaPostgres.swift`
- Test: `packages/TripSquadExpensesPostgres/Tests/TripSquadExpensesPostgresTests/RepositorioReservaPostgresTests.swift`

**Interfaces:**
- Produces: `RepositorioReservaPostgres: ReservaRepositorio` (mismas firmas del puerto).

- **Step 1: Escribe la migración `0008_reservas.sql`.**
```sql
CREATE TABLE itinerary_reservations (
    activity_id     TEXT PRIMARY KEY REFERENCES itinerary_items(id) ON DELETE CASCADE,
    trip_id         TEXT NOT NULL,
    kind            TEXT NOT NULL,
    mode            TEXT NOT NULL,            -- 'cada_uno' | 'uno_para_todos'
    responsible_id  TEXT,                     -- solo uno_para_todos
    single_estado   TEXT,                     -- solo uno_para_todos ('pendiente'|'reservado')
    created_at      TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_reservations_trip ON itinerary_reservations (trip_id);

CREATE TABLE itinerary_reservation_members (
    activity_id  TEXT NOT NULL REFERENCES itinerary_reservations(activity_id) ON DELETE CASCADE,
    member_id    TEXT NOT NULL,
    estado       TEXT NOT NULL,               -- 'pendiente' | 'reservado'
    PRIMARY KEY (activity_id, member_id)
);
```
(Verifica el nombre real de la tabla de actividades en `0005_itinerario.sql` — usa ese nombre exacto en el `REFERENCES`.)

- **Step 2: Escribe los tests Postgres que fallan.** Calca `RepositorioItinerarioPostgresTests.swift` (mismo harness de BD de test, skip si no hay `DATABASE_URL`). Casos: `upsert` + `reserva` round-trip de ambos modos; `marcarEstado` de un miembro; `tablero` ordenado; `upsert` reemplaza participantes; `borrar` limpia ambas tablas.

- **Step 3: Ejecuta y verifica que fallan.**
Run: `swift test --package-path packages/TripSquadExpensesPostgres --filter RepositorioReservaPostgresTests`
Expected: FAIL (no existe el adaptador).

- **Step 4: Implementa `RepositorioReservaPostgres.swift`.** Calca `RepositorioItinerarioPostgres.swift`: mismo `PostgresClient`, mismo `Codec`. `upsert` en transacción: `INSERT ... ON CONFLICT (activity_id) DO UPDATE` en `itinerary_reservations`, borra e inserta las filas de `itinerary_reservation_members` (reemplazo total). `reserva`/`tablero` reconstruyen el `ModoReserva` juntando ambas tablas. `marcarEstado` con `miembro` no-nil → `UPDATE itinerary_reservation_members`; con nil → `UPDATE itinerary_reservations SET single_estado`.

- **Step 5: Ejecuta y verifica que pasan** (con `DATABASE_URL` de test).
Run: `swift test --package-path packages/TripSquadExpensesPostgres --filter RepositorioReservaPostgresTests`
Expected: PASS.

- **Step 6: Commit.**
```bash
git add db/migrations/0008_reservas.sql \
        packages/TripSquadExpensesPostgres/Sources/TripSquadExpensesPostgres/RepositorioReservaPostgres.swift \
        packages/TripSquadExpensesPostgres/Tests/TripSquadExpensesPostgresTests/RepositorioReservaPostgresTests.swift
git commit -m "feat(reserva): adaptador Postgres + migracion 0008_reservas"
```

---

## Task 5: Limpieza del estado del expulsado (misma transacción que `quitarMiembro`)

**Files:**
- Modify: `packages/TripSquadExpensesPostgres/Sources/TripSquadExpensesPostgres/RepositorioViajePostgres.swift:203` (`quitarMiembro`)
- Modify: `packages/TripSquadExpenses/Sources/TripSquadExpenses/RepositorioEnMemoria.swift` (`quitarMiembro` del doble)
- Test: `packages/TripSquadExpensesPostgres/Tests/TripSquadExpensesPostgresTests/RepositorioViajePostgresTests.swift` (o el fichero donde ya se testee `quitarMiembro`) + un test en memoria en `RepositorioReservaEnMemoriaTests.swift`.

**Interfaces:** sin firmas nuevas — se refuerza el comportamiento de `quitarMiembro` existente.

**Regla:** al expulsar/salir un miembro, EN LA MISMA TRANSACCIÓN: (1) borrar sus filas de `itinerary_reservation_members` de ese viaje; (2) donde sea `responsible_id` de un `uno_para_todos`, poner `responsible_id = NULL` y `single_estado = 'pendiente'`. Consistente con "expulsar revoca huella" (el mismo `quitarMiembro` ya revoca invitaciones).

- **Step 1: Escribe el test que falla (en memoria).** Monta viaje con a (owner) y b; actividad; reservable `cadaUnoElSuyo([a,b])` + otro `unoParaTodos(responsable: b)`. Expulsa a b. Verifica: b ya no está en los estados del primero; el segundo tiene `responsable == nil` y `estado == .pendiente`.
```swift
@Test func expulsarLimpiaEstadoDeReserva() async throws {
    let f = try await fixtureConReservas()   // a owner, b miembro, 2 reservables como arriba
    try await f.repo.quitarMiembro(f.b, de: "t1", ahora: Date())
    let r1 = try await f.repo.reserva(activityId: "act1", en: "t1")   // cadaUnoElSuyo
    #expect(r1?.mode == .cadaUnoElSuyo(estados: [f.a: .pendiente]))
    let r2 = try await f.repo.reserva(activityId: "act2", en: "t1")   // unoParaTodos
    #expect(r2?.mode == .unoParaTodos(responsable: nil, estado: .pendiente))
}
```

- **Step 2: Ejecuta y verifica que falla.**
Run: `swift test --package-path packages/TripSquadExpenses --filter expulsarLimpiaEstadoDeReserva`
Expected: FAIL (el `quitarMiembro` en memoria aún no toca reservas).

- **Step 3: Implementa en `RepositorioEnMemoria.quitarMiembro`:** tras marcar la salida, recorre `reservas` de ese `tripId` y aplica la regla (quita al miembro del mapa `cadaUnoElSuyo`; si es el `responsable` de un `unoParaTodos`, ponlo a `nil`+`.pendiente`).

- **Step 4: Ejecuta y verifica que pasa.**
Run: `swift test --package-path packages/TripSquadExpenses --filter expulsarLimpiaEstadoDeReserva`
Expected: PASS.

- **Step 5: Replica en Postgres.** En `RepositorioViajePostgres.quitarMiembro`, dentro del `withTransaction` existente, añade tras el `UPDATE trip_invites`:
```swift
_ = try await conn.query("""
    DELETE FROM itinerary_reservation_members
    WHERE member_id = \(memberId.raw)
      AND activity_id IN (SELECT activity_id FROM itinerary_reservations WHERE trip_id = \(tripId))
    """, logger: self.logger)
_ = try await conn.query("""
    UPDATE itinerary_reservations SET responsible_id = NULL, single_estado = 'pendiente'
    WHERE trip_id = \(tripId) AND responsible_id = \(memberId.raw)
    """, logger: self.logger)
```

- **Step 6: Escribe y corre el test Postgres equivalente** (calca el patrón de `RepositorioViajePostgresTests` de invitaciones revocadas) y verifica PASS con `DATABASE_URL`.

- **Step 7: Commit.**
```bash
git add packages/TripSquadExpenses/Sources/TripSquadExpenses/RepositorioEnMemoria.swift \
        packages/TripSquadExpensesPostgres/Sources/TripSquadExpensesPostgres/RepositorioViajePostgres.swift \
        packages/TripSquadExpenses/Tests/TripSquadExpensesTests/RepositorioReservaEnMemoriaTests.swift \
        packages/TripSquadExpensesPostgres/Tests/TripSquadExpensesPostgresTests/RepositorioViajePostgresTests.swift
git commit -m "feat(reserva): expulsar/salir limpia estado de reserva en la misma transaccion"
```

---

## Task 6: ADR + build/test completo

**Files:**
- Create: `docs/decisions/00XX-reservas-por-persona.md` (siguiente número libre)

- **Step 1: Escribe el ADR** (usa `docs/decisions/_TEMPLATE.md`). Registra: el estado de reserva vive sobre `ActividadItinerario`; 2 estados (pendiente/reservado); 2 modos (cadaUnoElSuyo con subconjunto / unoParaTodos con responsable); auth (cada uno el suyo + owner cualquiera; definir/quitar = creador u owner); errores sin fuga de existencia; limpieza transaccional al expulsar. Enlaza el spec `docs/superpowers/specs/2026-07-25-wedge-reserva-por-persona-design.md`.

- **Step 2: Build + test de todo el workspace.**
Run: `for p in TripSquadDomain TripSquadExpenses TripSquadExpensesPostgres TripSquadService; do swift build --package-path packages/$p && swift test --package-path packages/$p; done`
Expected: todo verde (los tests Postgres se saltan si no hay `DATABASE_URL`).

- **Step 3: Commit.**
```bash
git add docs/decisions/00XX-reservas-por-persona.md
git commit -m "docs(reserva): ADR del wedge quien ya reservo"
```

---

## Self-Review (cobertura del spec)

- **Modelo sobre itinerario, tipo + 2 modos + 2 estados + subconjunto** → Task 1 (tipos) + Task 2 (`definir`). ✅
- **Auth: definir/quitar = creador u owner; marcar = cada uno el suyo + owner cualquiera** → Task 2 + tests. ✅
- **Errores sin fuga de existencia (noAutorizado 403), viajeCerrado 409, reglaViolada 422** → Task 2 (dominio) + Task 3 (mapeo HTTP). ✅
- **Endpoints (PUT reservation, PUT status, DELETE, GET tablero) + GET itinerario con badge** → Task 3. (El badge en el GET de itinerario es un extra de conveniencia; si se quiere, se añade un campo `reservaResumen` al `ActividadDTO` leyendo `repo.reserva` — anotarlo como sub-paso opcional en Task 3.) ✅
- **Persistencia + cascada con la actividad** → Task 4 (migración `ON DELETE CASCADE`). ✅
- **Limpieza transaccional al expulsar** → Task 5. ✅
- **ADR** → Task 6. ✅
- **Fuera de alcance (notificaciones, 3er estado, auto-detección, front)** → no hay tareas, correcto.
