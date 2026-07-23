# M5 — Itinerario — Scope + decisiones provisionales + plan

> PROPUESTA autónoma (mandato "no pares"). Defaults revocables por Andrea → ADR-0020 al firmar.
> Stack sobre M4. Extiende los paquetes existentes.

## Idea
Actividades del viaje organizadas por día: "día 2, 10:00, Coliseo". CRUD simple, scope por miembro.

## Decisiones provisionales (ADR-0020 borrador)
1. **Añadir actividad:** cualquier miembro del viaje.
2. **Editar/borrar:** el **creador** de la actividad **o el owner** del viaje (mismo criterio que cerrar votación).
3. **Ver:** solo miembros (403 sin fuga).
4. **Orden:** `orderIndex` entero dentro del día; el cliente ordena por (day, orderIndex, startTime).
5. Añadir/editar en viaje **cerrado** → rechazo.
6. Campos: `title` (obligatorio), `day` (date, obligatorio), `startTime?` (string HH:mm), `location?`, `notes?`.

## PREGUNTAS ABIERTAS
- ¿Editar/borrar restringido a creador+owner, o cualquier miembro (squad colaborativo)? Provisional: creador+owner.
- ¿Reordenar por endpoint dedicado o vía PATCH de orderIndex? Provisional: PATCH del orderIndex.

## Migración 0005
```sql
create table itinerary_items (
    id          text primary key,
    trip_id     text not null references trips(id),
    title       text not null,
    day         date not null,
    start_time  text,                 -- 'HH:mm' o null
    location    text,
    notes       text,
    order_index int  not null default 0,
    created_by  text not null,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);
create index if not exists idx_itinerary_trip_day on itinerary_items (trip_id, day, order_index);
```

## Contrato de dominio (TripSquadExpenses)
```swift
public struct ActividadItinerario: Equatable, Sendable {
    public let id: String; public let tripId: String; public let title: String
    public let day: String            // ISO date 'YYYY-MM-DD' (el dominio no interpreta fechas)
    public let startTime: String?; public let location: String?; public let notes: String?
    public let orderIndex: Int; public let createdBy: MiembroId
}
public protocol ItinerarioRepositorio: Sendable {
    func crear(_ a: ActividadItinerario, ahora: Date) async throws
    func listar(_ tripId: String) async throws -> [ActividadItinerario]   // ordenado por day, orderIndex
    func item(id: String, en tripId: String) async throws -> ActividadItinerario?
    func actualizar(_ a: ActividadItinerario, ahora: Date) async throws
    func borrar(id: String, en tripId: String) async throws
}
```
`CasosDeUsoItinerario(repo:, membresia:, viajes:)`:
- `crear(tripId, campos, actor, ahora)` → solo miembro; viaje no cerrado; genera id (UUID); title no vacío.
- `listar(tripId, actor)` → solo miembro (403 sin fuga).
- `editar(itemId, tripId, campos, actor, ahora)` → creador de la actividad O owner; viaje no cerrado.
- `borrar(itemId, tripId, actor, ahora)` → creador O owner.

## Endpoints
- `POST /trips/:tripId/itinerary` {title, day, startTime?, location?, notes?, orderIndex?} → 201.
- `GET /trips/:tripId/itinerary` → 200 `{items:[...]}` ordenado.
- `PATCH /trips/:tripId/itinerary/:itemId` {campos} → 200 · 403 · 404.
- `DELETE /trips/:tripId/itinerary/:itemId` → 204 · 403 · 404.

## Tareas (TDD, subagentes)
1. Dominio: modelo + puerto + `CasosDeUsoItinerario` con autorización + RepositorioEnMemoria + tests (crear, listar orden, no-miembro 403 sin fuga, solo creador/owner edita/borra, viaje cerrado rechaza) + migración 0005.
2. Postgres: `RepositorioPostgres: ItinerarioRepositorio` + tests integración.
3. Service: 4 endpoints + tests autorización.
4. Seguridad: revisión + arreglos.
