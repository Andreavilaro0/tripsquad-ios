-- Migración 0011 — topes de longitud en campos de texto libre (bead mjp,
-- hallazgo de la revisión integrada). Append-only: solo añade, no reescribe
-- migraciones previas.
--
-- Contexto: solo `messages.body` (0006_chat.sql, 4000 code points) llevaba un
-- CHECK de longitud en BD. El resto de texto libre sin dueño (nombre/moneda de
-- viaje, pregunta/opciones de votación, título/notas/ubicación de itinerario,
-- caption de foto, motivo de rechazo de settlement) no tenía tope — un vector
-- de abuso/coste/DoS. La validación de dominio ya se añadió en el mismo bead
-- en `CasosDeUsoViaje`/`CasosDeUsoVotacion`/`CasosDeUsoItinerario`/
-- `CasosDeUsoFoto`/`CasosDeUsoSettle` (packages/TripSquadExpenses); este CHECK
-- es la defensa en BD (segunda capa, mismo criterio que 0006_chat.sql —
-- "defensa en BD" en el comentario de esa migración).
--
-- UNIDAD: `char_length` de Postgres cuenta code points (Unicode scalars), no
-- bytes ni grapheme clusters — la capa de dominio mide con
-- `String.unicodeScalars.count`, la MISMA unidad, para que un valor que pasa
-- el dominio nunca reviente este CHECK como 5xx (ver el razonamiento completo
-- en `CasosDeUsoChat.enviar`).
--
-- IDEMPOTENCIA: Postgres NO soporta `ADD CONSTRAINT IF NOT EXISTS` (probado
-- contra 16.14 local — error de sintaxis), así que cada CHECK se envuelve en
-- un `DO` que mira `pg_constraint` antes de añadirlo. Re-ejecutar esta
-- migración es un no-op.
--
-- LÍMITES (default razonable de Andrea, bead mjp — sin decisión de producto
-- explícita para cada campo, elegidos por analogía con lo ya existente):
--   - Títulos/nombres cortos (trips.name, itinerary_items.title/location,
--     cada opción de polls.options): 200, mismo orden que un titular.
--   - Texto libre más largo (itinerary_items.notes): 4000, igual que
--     messages.body (0006_chat.sql) — mismo tipo de campo, "una nota", no una
--     conversación entera pero tampoco un titular.
--   - Frases medias (polls.question, photos.caption,
--     settlements.reject_reason): 500 — más que un título, menos que una nota.
--   - trips.base_currency: 10 — es un código ISO 4217 de 3 letras
--     (Viaje.swift), 10 es techo de sobra sin fijar el formato aquí (eso
--     sería otra validación, fuera de alcance de este bead).
--   - Cardinalidad de polls.options: 20 — la BD solo exigía `>= 2`
--     (0004_votaciones.sql); sin techo, un array de miles de opciones es el
--     mismo vector de abuso que un string sin límite.

-- --- trips (name, base_currency) ---

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'ck_trips_name_len') then
        alter table trips add constraint ck_trips_name_len check (char_length(name) <= 200);
    end if;
end $$;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'ck_trips_base_currency_len') then
        alter table trips add constraint ck_trips_base_currency_len check (char_length(base_currency) <= 10);
    end if;
end $$;

-- --- polls (question, options: longitud por elemento + cardinalidad) ---
--
-- `options` es jsonb (array de strings); Postgres NO permite subconsultas
-- dentro de un CHECK (probado contra 16.14 local — "no se pueden usar
-- subconsultas en una restricción «check»"), así que la validación por
-- elemento vive en una función SQL inmutable, y el CHECK solo LLAMA a la
-- función (eso sí es una expresión simple, no una subconsulta inline).

create or replace function opciones_votacion_validas(options jsonb, max_opciones int, max_longitud_opcion int)
returns boolean
language sql
immutable
as $$
    select jsonb_array_length(options) <= max_opciones
       and not exists (
           select 1 from jsonb_array_elements_text(options) v
           where char_length(v) > max_longitud_opcion
       )
$$;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'ck_polls_question_len') then
        alter table polls add constraint ck_polls_question_len check (char_length(question) <= 500);
    end if;
end $$;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'ck_polls_options_len') then
        alter table polls add constraint ck_polls_options_len check (opciones_votacion_validas(options, 20, 200));
    end if;
end $$;

-- --- itinerary_items (title, location, notes) ---

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'ck_itinerary_items_title_len') then
        alter table itinerary_items add constraint ck_itinerary_items_title_len check (char_length(title) <= 200);
    end if;
end $$;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'ck_itinerary_items_location_len') then
        alter table itinerary_items add constraint ck_itinerary_items_location_len check (char_length(location) <= 200);
    end if;
end $$;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'ck_itinerary_items_notes_len') then
        alter table itinerary_items add constraint ck_itinerary_items_notes_len check (char_length(notes) <= 4000);
    end if;
end $$;

-- --- photos (caption) ---

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'ck_photos_caption_len') then
        alter table photos add constraint ck_photos_caption_len check (char_length(caption) <= 500);
    end if;
end $$;

-- --- settlements (reject_reason) ---

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'ck_settlements_reject_reason_len') then
        alter table settlements add constraint ck_settlements_reject_reason_len check (char_length(reject_reason) <= 500);
    end if;
end $$;
