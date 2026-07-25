-- Migración 0009 — confirmaciones de reserva (dy5 "confirmaciones → auto-marca
-- el wedge"). Append-only: solo añade, no reescribe migraciones previas.
--
-- `itinerary_reservation_confirmations` guarda, por miembro/actividad, la
-- confirmación extraída de un texto libre (LLM) — ver
-- packages/TripSquadExpenses/Sources/TripSquadExpenses/Confirmacion.swift.
-- FK a `itinerary_reservations(activity_id)` (migración 0008) con ON DELETE
-- CASCADE: si se borra el aspecto reserva de la actividad, sus confirmaciones
-- desaparecen con él. PK compuesta (activity_id, member_id): una confirmación
-- por miembro y actividad, se REEMPLAZA si ya existía (mismo criterio que el
-- `upsert` de `itinerary_reservations`).

create table itinerary_reservation_confirmations (
    activity_id           text not null references itinerary_reservations(activity_id) on delete cascade,
    member_id             text not null,
    tipo                  text not null,
    fecha_iso             text,
    numero_confirmacion   text,
    proveedor             text,
    created_at            timestamptz not null,
    primary key (activity_id, member_id)
);
