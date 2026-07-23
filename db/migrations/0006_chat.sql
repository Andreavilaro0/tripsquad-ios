-- Migración 0006 — chat (M6, ADR-0021 borrador —
-- docs/design/chat-scope-y-plan.md). Append-only: solo añade, no reescribe
-- migraciones previas.

create table messages (
    id          bigint generated always as identity primary key,   -- cursor monotónico
    trip_id     text not null references trips(id),
    member_id   text not null,
    body        text not null,
    deleted_at  timestamptz,
    created_at  timestamptz not null default now()
);
create index if not exists idx_messages_trip_id on messages (trip_id, id);
