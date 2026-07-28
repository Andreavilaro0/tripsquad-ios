-- Migración 0007 — fotos (M7 Task 1, ADR-0022 borrador —
-- docs/design/fotos-plan-stub.md / docs/design/fotos-scope.md §Esquema).
-- Append-only: solo añade, no reescribe migraciones previas.
--
-- El binario NO se guarda en Postgres: solo el metadato + `storage_key`, que
-- apunta al object storage (stub hoy, adaptador real cuando se decida el
-- proveedor — ADR-0022).

create table photos (
    id           text primary key,
    trip_id      text not null references trips(id),
    uploaded_by  text not null,
    storage_key  text not null,          -- ruta en el bucket
    content_type text not null,
    size_bytes   bigint,
    caption      text,
    status       text not null default 'pending' check (status in ('pending','ready')),
    created_at   timestamptz not null default now()
);
create index if not exists idx_photos_trip on photos (trip_id, created_at);
