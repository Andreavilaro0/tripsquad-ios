-- Migración 0010 — etag/If-Match en itinerario (bead 201, enmienda al
-- borrador de ADR-0020 — docs/design/itinerario-scope-y-plan.md). Append-only:
-- solo añade, no reescribe migraciones previas.
--
-- Hallazgo: `PATCH /trips/:tripId/itinerary/:itemId` era el único recurso
-- editable (además de gastos) SIN control de concurrencia optimista. Gastos ya
-- tiene `etag` desde la migración 0001 (ADR-0013 §2); itinerario no, así que
-- dos ediciones concurrentes se pisaban en silencio (last-write-wins). Mismo
-- patrón que `expenses.etag`: un valor de texto que cambia en cada UPDATE, con
-- el PATCH exigiendo `If-Match` y comparándolo ATÓMICAMENTE en el WHERE del
-- UPDATE (ver RepositorioItinerarioPostgres.actualizar) — 0 filas afectadas =
-- conflicto (412), no una lectura-antes-de-escribir que pueda perderse en una
-- carrera (TOCTOU).
--
-- `default gen_random_uuid()::text` sella las filas que ya existieran con un
-- etag inicial distinto por fila (no hay ninguna en dev/staging todavía, pero
-- la migración es correcta igual si las hubiera); `drop default` después deja
-- el mismo contrato que `expenses.etag`: el valor SIEMPRE lo genera la
-- aplicación en cada INSERT/UPDATE, nunca la base de datos por su cuenta.

alter table itinerary_items add column etag text not null default gen_random_uuid()::text;
alter table itinerary_items alter column etag drop default;
