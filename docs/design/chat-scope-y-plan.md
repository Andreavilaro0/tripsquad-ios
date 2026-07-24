# M6 — Chat — Scope + decisiones provisionales + plan (MVP store)

> PROPUESTA autónoma. Este MVP construye SOLO el **almacén de mensajes + lectura por polling**
> (reutilizable con cualquier transporte). El **realtime** (WebSocket/SSE propio vs 3rd-party
> como Ably/Pusher/Supabase Realtime) es una **decisión de arquitectura + posible dependencia**
> que NO se toma en autónomo — queda para Andrea (muro duro). Defaults revocables → ADR-0021.

## Idea
Chat por viaje. MVP: enviar mensaje + listar mensajes (paginado por cursor `since`). El cliente
hace polling. Cuando se decida el realtime, el mismo almacén se expone por push.

## Decisiones provisionales (ADR-0021 borrador)
1. **Enviar/leer:** solo miembros del viaje (403 sin fuga).
2. **Mensaje:** `body` texto, máx 4000 chars (rechazo si vacío o >límite). Sin edición en MVP.
3. **Borrar:** borrado propio (soft-delete: `deleted_at`; el body se sustituye por marcador). Solo el autor. (Provisional — ¿o también owner? pregunta abierta.)
4. **Paginación:** `GET .../messages?since=<cursor>&limit=<n>` — cursor = id monotónico o created_at; devuelve en orden cronológico, `limit` por defecto 50, máx 200.
5. **Viaje cerrado:** ¿se puede seguir chateando en un viaje cerrado? Provisional: **sí** (el chat es memoria del viaje, no una mutación de contenido). Pregunta abierta.

## MURO DURO (Andrea decide, NO autónomo)
- **Realtime transport:** WebSocket/SSE propio (Hummingbird lo soporta) vs 3rd-party (Ably/Pusher/
  Supabase Realtime = dependencia + credenciales + posible coste). Este MVP NO lo implementa.
- Notificaciones push a móvil (APNs) — infra aparte.

## Migración 0006
```sql
create table messages (
    id          bigint generated always as identity primary key,   -- cursor monotónico
    trip_id     text not null references trips(id),
    member_id   text not null,
    body        text not null,
    deleted_at  timestamptz,
    created_at  timestamptz not null default now()
);
create index if not exists idx_messages_trip_id on messages (trip_id, id);
```

## Contrato de dominio (TripSquadExpenses)
```swift
public struct Mensaje: Equatable, Sendable {
    public let id: Int64; public let tripId: String; public let autor: MiembroId
    public let body: String; public let deletedAt: Date?; public let createdAt: Date
}
public enum ResultadoEnviar: Equatable, Sendable { case enviado(Mensaje); case rechazado(razon: String) }
public protocol ChatRepositorio: Sendable {
    func enviar(tripId: String, autor: MiembroId, body: String, ahora: Date) async throws -> Mensaje
    func mensajes(tripId: String, since: Int64?, limit: Int) async throws -> [Mensaje]   // cronológico, id > since
    func mensaje(id: Int64, en tripId: String) async throws -> Mensaje?
    func borrar(id: Int64, en tripId: String, ahora: Date) async throws
}
```
`CasosDeUsoChat(repo:, membresia:)`:
- `enviar(tripId, body, actor, ahora)` → solo miembro; body no vacío y ≤4000; devuelve el Mensaje.
- `listar(tripId, actor, since, limit)` → solo miembro (403 sin fuga); limit clamp [1,200].
- `borrar(msgId, tripId, actor, ahora)` → solo el autor del mensaje (soft-delete).

## Endpoints
- `POST /trips/:tripId/messages` {body} → 201 `{id, author, body, createdAt}`.
- `GET /trips/:tripId/messages?since=&limit=` → 200 `{messages:[...], nextSince}`.
- `DELETE /trips/:tripId/messages/:messageId` → 204 (solo autor) · 403 · 404.

## Tareas (TDD, subagentes)
1. Dominio: modelo + puerto + `CasosDeUsoChat` con autorización + RepositorioEnMemoria (id autoincremental) + tests (enviar, límite de body, no-miembro 403 sin fuga, listar since/limit orden cronológico, borrar solo autor) + migración 0006.
2. Postgres: `RepositorioPostgres: ChatRepositorio` (id identity; since = id > cursor) + tests integración.
3. Service: 3 endpoints + tests autorización.
4. Seguridad: revisión + arreglos.
