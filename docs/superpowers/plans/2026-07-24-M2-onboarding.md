# M2 — Onboarding (viajes + miembros) — Implementation Plan

> REQUIRED SUB-SKILL: subagent-driven-development. Implementa ADR-0018 (provisional).
> Extiende los paquetes existentes (no crea paquetes nuevos): dominio/puertos/casos en
> `TripSquadExpenses`, adaptador en `TripSquadExpensesPostgres`, rutas en `TripSquadService`.

**Goal:** un squad puede crear un viaje, invitar por código, unirse, ver miembros, salir/expulsar y cerrar — todo por API autenticada.

**Global Constraints:** actor siempre del JWT. Autorización estricta (abajo). `code` de invitación aleatorio ≥128 bits. No filtrar existencia a no-autorizados (403 uniforme). Dinero N/A aquí. Migración append-only (0003).

## Contrato de dominio (TripSquadExpenses)

```swift
public enum RolMiembro: String, Sendable, Equatable { case owner, member }

public struct Viaje: Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseCurrency: String     // 'EUR' por defecto
    public let createdBy: MiembroId
    public let closedAt: Date?
}

public struct Invitacion: Equatable, Sendable {
    public let code: String
    public let tripId: String
    public let createdBy: MiembroId
    public let expiresAt: Date
    public let revokedAt: Date?
}

public enum ResultadoUnirse: Equatable, Sendable {
    case unido
    case yaMiembro
    case codigoInvalido      // no existe
    case caducado
    case revocado
    case viajeCerrado
    case lleno               // > tope 50
}

public protocol ViajeRepositorio: Sendable {
    func crearViaje(id: String, name: String, baseCurrency: String, creador: MiembroId, ahora: Date) async throws -> Viaje
    func viaje(id: String) async throws -> Viaje?
    func viajesDe(_ actor: MiembroId) async throws -> [Viaje]
    func miembros(de tripId: String) async throws -> [(MiembroId, RolMiembro)]
    func rol(de actor: MiembroId, en tripId: String) async throws -> RolMiembro?   // nil = no miembro
    func crearInvitacion(tripId: String, por: MiembroId, code: String, expiresAt: Date) async throws -> Invitacion
    func revocarInvitacion(code: String, en tripId: String, ahora: Date) async throws -> Bool
    func unirsePorCodigo(code: String, actor: MiembroId, ahora: Date, tope: Int) async throws -> ResultadoUnirse
    func quitarMiembro(_ memberId: MiembroId, de tripId: String, ahora: Date) async throws
    func cerrar(tripId: String, ahora: Date) async throws
}
```

`CasosDeUsoViaje` (autorización — SEGURIDAD):
- `crear(name, baseCurrency, actor)` → genera id + code aleatorio; el actor entra como `owner`.
- `listarMisViajes(actor)` → `viajesDe`.
- `detalle(tripId, actor)` → SOLO si `rol(actor) != nil`; si no, `noAutorizado` (403, no filtra existencia).
- `invitar(tripId, actor)` → SOLO si `rol(actor) != nil` (cualquier miembro). Devuelve code. Rechaza si viaje cerrado.
- `revocar(code, tripId, actor)` → SOLO `owner`.
- `unirse(code, actor)` → `unirsePorCodigo` (valida caducado/revocado/cerrado/lleno/yaMiembro).
- `salir(tripId, actor)` → un miembro se quita a sí mismo (marca left_at). (Aviso si saldo != 0 se resuelve en la capa HTTP con settle — opcional MVP.)
- `expulsar(tripId, memberId, actor)` → SOLO `owner`, y no puede expulsarse a sí mismo por esta vía (usa salir). El owner no puede ser expulsado.
- `cerrar(tripId, actor)` → SOLO `owner`.

**Generación de code:** aleatorio, ≥128 bits, url-safe. Como `Math.random`/UUID aleatorio no
está disponible en algunos contextos deterministas, aquí SÍ (es runtime real): usar
`SystemRandomNumberGenerator` / `UUID()`. El `code` es la PK de `trip_invites`.

## Tareas
1. **Dominio** (TripSquadExpenses): modelos + `ViajeRepositorio` + `CasosDeUsoViaje` + impl en `RepositorioEnMemoria` + tests (crear, unirse feliz, código caducado/revocado, no-miembro no ve detalle, solo-owner expulsa/cierra, tope lleno, yaMiembro idempotente). Migración **0003**.
2. **Postgres** (TripSquadExpensesPostgres): `RepositorioViajePostgres` (o extender) implementa `ViajeRepositorio` + tests de integración.
3. **Service**: rutas `POST /trips`, `GET /trips`, `GET /trips/:id`, `POST /trips/:id/invites`, `POST /trips/join`, `DELETE /trips/:id/members/:memberId`, `POST /trips/:id/close` + tests HTTP (incl. autorización: no-miembro→403, no-owner→403).
4. **Seguridad**: revisión multi-modelo + `/cso` (OWASP/STRIDE) sobre el diff; arreglar hallazgos.

## Migración 0003 (append-only)
```sql
alter table trips
    add column name text not null default '',
    add column base_currency text not null default 'EUR',
    add column created_by text not null default '',
    add column created_at timestamptz not null default now();
alter table trip_members
    add column role text not null default 'member' check (role in ('owner','member')),
    add column joined_at timestamptz not null default now();
create table trip_invites (
    code        text primary key,
    trip_id     text not null references trips(id),
    created_by  text not null,
    expires_at  timestamptz not null,
    revoked_at  timestamptz,
    created_at  timestamptz not null default now()
);
create index if not exists idx_trip_members_member on trip_members (member_id) where left_at is null;
```
NOTA: `trips`/`trip_members` están vacías (no prod), así que los `default ''` no afectan filas reales.
