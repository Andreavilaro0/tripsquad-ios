# M4 — Votaciones — Scope + decisiones provisionales + plan

> PROPUESTA autónoma (mandato "no pares"). Decisiones = defaults conservadores **revocables**
> por Andrea. Debe formalizarse como **ADR-0019** cuando ella firme. Stack: sobre M2 (usa la
> membresía real y el rol owner de onboarding). Extiende los paquetes existentes.

## Qué existe
`poll_votes (poll_id, member_id, choice, created_at, PK(poll_id, member_id))` — 1 voto por
miembro por votación (dedupe estructural, ADR-0012 §2). Falta la tabla `polls`.

## Decisiones provisionales (ADR-0019 borrador)
1. **Crear votación:** cualquier miembro del viaje. Campos: `question` + lista de `options` (≥2).
2. **Votar:** un miembro elige una `option` válida. **Cambiable hasta que se cierre** (UPSERT sobre (poll_id, member_id)). Votar una option inexistente → rechazo.
3. **Cerrar:** el **creador** de la votación **o el owner** del viaje. Tras cerrar, no se vota más.
4. **Resultados:** conteo por opción + **votantes visibles** a los miembros (squad transparente). (Alternativa: anónimo — pregunta abierta.)
5. **Ver/crear/votar:** SOLO miembros del viaje (403 uniforme, sin fuga, como onboarding).
6. Votar/crear en viaje **cerrado** → rechazo (coherencia con onboarding/settle).

## PREGUNTAS ABIERTAS (Andrea)
- ¿Votos **visibles** (quién votó qué) o **anónimos** (solo conteos)? Provisional: visibles.
- ¿Caducidad automática de la votación (`closes_at`) o solo cierre manual? Provisional: solo manual.
- ¿Empates / desempate? Provisional: se muestran, sin lógica de desempate.

## Migración 0004
```sql
create table polls (
    id          text primary key,
    trip_id     text not null references trips(id),
    question    text not null,
    options     jsonb not null,               -- array de strings, ≥2
    created_by  text not null,
    created_at  timestamptz not null default now(),
    closed_at   timestamptz
);
create index if not exists idx_polls_trip on polls (trip_id);
create index if not exists idx_poll_votes_poll on poll_votes (poll_id);
-- FK de poll_votes.poll_id -> polls.id (antes poll_votes existía sin la tabla polls):
alter table poll_votes add constraint fk_poll_votes_poll
    foreign key (poll_id) references polls(id) on delete cascade;
```

## Contrato de dominio (TripSquadExpenses)
```swift
public struct Votacion: Equatable, Sendable {
    public let id: String; public let tripId: String; public let question: String
    public let options: [String]; public let createdBy: MiembroId; public let closedAt: Date?
}
public struct ResultadoVotacion: Equatable, Sendable {   // para GET detalle
    public let votacion: Votacion
    public let conteo: [String: Int]                 // option -> nº votos
    public let votos: [(MiembroId, String)]          // quién votó qué (si visible)
}
public enum ResultadoVotar: Equatable, Sendable { case registrado; case rechazado(razon: String) }

public protocol VotacionRepositorio: Sendable {
    func crear(_ v: Votacion) async throws
    func votacion(id: String, en tripId: String) async throws -> Votacion?
    func votacionesDe(_ tripId: String) async throws -> [Votacion]
    func votar(pollId: String, tripId: String, member: MiembroId, choice: String, ahora: Date) async throws -> ResultadoVotar
    func resultado(pollId: String, en tripId: String) async throws -> ResultadoVotacion?
    func cerrar(pollId: String, en tripId: String, ahora: Date) async throws
}
```
`CasosDeUsoVotacion` (autorización, usa `Membresia` + `ViajeRepositorio.rol`):
- `crear(tripId, question, options, actor, ahora)` → solo miembro; ≥2 opciones; viaje no cerrado.
- `listar(tripId, actor)` / `detalle(pollId, tripId, actor)` → solo miembro (403 sin fuga).
- `votar(pollId, tripId, choice, actor, ahora)` → solo miembro; poll no cerrada; choice ∈ options; UPSERT.
- `cerrar(pollId, tripId, actor)` → solo el creador de la poll O el owner del viaje.

## Endpoints (Service)
- `POST /trips/:tripId/polls` {question, options} → 201.
- `GET /trips/:tripId/polls` → 200 lista.
- `GET /trips/:tripId/polls/:pollId` → 200 con resultados (conteo + votantes).
- `POST /trips/:tripId/polls/:pollId/vote` {choice} → 200 registrado / 422 razon.
- `POST /trips/:tripId/polls/:pollId/close` → 200 (creador u owner) / 403.

## Tareas (TDD, subagentes)
1. Dominio: modelos + puerto + `CasosDeUsoVotacion` con autorización + `RepositorioEnMemoria` + tests (crear, votar feliz, cambiar voto, option inválida, votar en cerrada, no-miembro no ve/vota, solo creador/owner cierra) + migración 0004.
2. Postgres: `RepositorioPostgres: VotacionRepositorio` (votar = INSERT ON CONFLICT DO UPDATE) + tests integración.
3. Service: 5 endpoints + tests HTTP (autorización).
4. Seguridad: revisión 3 modelos + arreglos.
