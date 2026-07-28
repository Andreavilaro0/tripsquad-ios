-- Migración 0005 — itinerario (M5, ADR-0020 borrador —
-- docs/design/itinerario-scope-y-plan.md). Append-only: solo añade, no
-- reescribe migraciones previas.

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
