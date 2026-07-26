-- Migración 0008 — reservas (wedge "quién ya reservó", spec
-- docs/superpowers/specs/2026-07-25-wedge-reserva-por-persona-design.md). Append-only: solo añade,
-- no reescribe migraciones previas.
--
-- `itinerary_reservations` es el aspecto reserva de UNA actividad de
-- itinerario (1:1, PK = activity_id, FK a itinerary_items con ON DELETE
-- CASCADE de la migración 0005: si se borra la actividad, su reserva
-- desaparece con ella). `itinerary_reservation_members` guarda los estados
-- por miembro del modo `cada_uno`; en `uno_para_todos` esa tabla queda vacía
-- y el estado único vive en `itinerary_reservations.single_estado`.

create table itinerary_reservations (
    activity_id     text primary key references itinerary_items(id) on delete cascade,
    trip_id         text not null,
    kind            text not null,
    mode            text not null,            -- 'cada_uno' | 'uno_para_todos'
    responsible_id  text,                      -- solo uno_para_todos
    single_estado   text,                      -- solo uno_para_todos ('pendiente'|'reservado')
    created_at      timestamptz not null default now()
);
create index if not exists idx_reservations_trip on itinerary_reservations (trip_id);

create table itinerary_reservation_members (
    activity_id  text not null references itinerary_reservations(activity_id) on delete cascade,
    member_id    text not null,
    estado       text not null,               -- 'pendiente' | 'reservado'
    primary key (activity_id, member_id)
);
