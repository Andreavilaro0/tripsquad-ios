-- Migración 0014 — mecanismo de RLS con rol de servicio (ADR-0030, bead 5n3).
-- CIERRA el PENDIENTE que dejaba 0001_expenses.sql:140-143.
--
-- Decisión FIRMADA por Andrea (2026-07-28, ADR-0030): mecanismo A+B del doc de
-- investigación docs/design/rls-mecanismo-investigacion-5n3.md:
--   A) el servicio emula a PostgREST por transacción: SET LOCAL role = authenticated
--      + set_config('request.jwt.claims', {sub: userId}, true) (helper Swift
--      `enTransaccionConRol(actor:)`), para que las policies se evalúen por-usuario;
--   B) la membresía se resuelve en funciones `security definer` del esquema `private`
--      (con `set search_path=''`), invocadas por las policies, evitando la recursión RLS.
--
-- Modelo de autorización (ADR-0009 §4 Zero-Trust):
--   · Capa 1 (fuente de verdad de authz fina): el dominio (CasosDeUso*) — ownership,
--     ETag, viaje cerrado, dedupe. Ya testeado.
--   · Capa 2 (esta migración): RLS como BARRERA por-viaje y por-usuario. Ninguna
--     conexión que asuma `authenticated` puede leer/escribir filas de un viaje del que
--     el `sub` del claim NO es miembro activo — ni siquiera bajo el rol de servicio.
--   Por eso las policies acotan por MEMBRESÍA (private.es_miembro), no por ownership:
--   "todos editan" dentro de un viaje (ADR-0015 §15) es válido; el ownership fino lo
--   sigue haciendo la capa 1.
--
-- Fuente (Context7 /supabase/supabase): patrón `private` + security definer + policies
-- (apps/docs/.../pgtap-extended.mdx) y emulación PostgREST via set_config('role',...)
-- + request.jwt.claims (packages/pg-meta/.../role-impersonation.ts).
--
-- Idempotente en re-ejecución local: `enable row level security` no falla al repetir y
-- cada policy se `drop ... if exists` antes de crearse.

-- 0. Rol `authenticated` -------------------------------------------------------
-- En Supabase existe de fábrica; en un Postgres vanilla (contenedor de CI/local) hay
-- que crearlo. SIN LOGIN (se asume vía SET ROLE, nunca conecta) y SIN BYPASSRLS (por
-- defecto): si tuviera BYPASSRLS las policies ni se evaluarían.
do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated nologin noinherit;
    end if;
end $$;

-- 1. Esquema privado + funciones de membresía (Opción B) -----------------------
-- NUNCA se expone en la API (no se añade a PGRST_DB_SCHEMAS). `authenticated` recibe
-- USAGE + EXECUTE porque las policies las invocan en su nombre; se revoca de PUBLIC.
create schema if not exists private;
revoke all on schema private from public;

-- Identidad del actor = claim `sub` de request.jwt.claims (lo fija el helper Swift, o
-- PostgREST si algún día se usa). `missing_ok=true` -> NULL si no hay claim (no error):
-- con NULL toda policy de membresía niega, que es el fallo-seguro deseado.
create or replace function private.uid()
returns text
language sql
stable
set search_path = ''
as $$
    select nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
$$;

-- ¿`p_usuario` es miembro ACTIVO (left_at is null) de `p_trip`? security definer para
-- leer trip_members sin disparar su propia RLS -> sin recursión (patrón Supabase).
create or replace function private.es_miembro(p_trip text, p_usuario text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.trip_members
        where trip_id = p_trip and member_id = p_usuario and left_at is null
    )
$$;

-- Rol del usuario en el viaje ('owner' | 'member' | null si no es miembro activo).
create or replace function private.rol_en_viaje(p_trip text, p_usuario text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
    select role from public.trip_members
    where trip_id = p_trip and member_id = p_usuario and left_at is null
$$;

-- Membresía por tabla-hija (sin trip_id propio): se resuelve el viaje vía el padre.
create or replace function private.es_miembro_de_gasto(p_expense text, p_usuario text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.expenses e
        join public.trip_members tm on tm.trip_id = e.trip_id
        where e.id = p_expense and tm.member_id = p_usuario and tm.left_at is null
    )
$$;

create or replace function private.es_miembro_de_poll(p_poll text, p_usuario text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.polls p
        join public.trip_members tm on tm.trip_id = p.trip_id
        where p.id = p_poll and tm.member_id = p_usuario and tm.left_at is null
    )
$$;

create or replace function private.es_miembro_de_reserva(p_activity text, p_usuario text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.itinerary_reservations r
        join public.trip_members tm on tm.trip_id = r.trip_id
        where r.activity_id = p_activity and tm.member_id = p_usuario and tm.left_at is null
    )
$$;

-- ¿Existe una invitación VÁLIDA (no revocada, no caducada) para el viaje? security definer
-- para leer trip_invites sin disparar su RLS: un no-miembro aún no ve las invitaciones,
-- pero la defensa en profundidad del self-join SÍ debe poder comprobar que hay una vigente
-- (P1 Codex #60: sin esto, cualquiera con el trip_id se autoañadía sin invitación).
create or replace function private.hay_invitacion_valida(p_trip text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.trip_invites i
        where i.trip_id = p_trip and i.revoked_at is null and i.expires_at > now()
    )
$$;

-- ¿El viaje ya tiene ALGÚN miembro? Distingue el bootstrap del creador (primer miembro ->
-- owner) de un self-join posterior. security definer -> lee trip_members sin recursión RLS.
create or replace function private.viaje_tiene_miembros(p_trip text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (select 1 from public.trip_members where trip_id = p_trip)
$$;

-- ¿`p_usuario` es el CREADOR registrado del viaje? (trips.created_by). Ata el bootstrap del
-- owner al creador real, no a cualquiera que sepa el trip_id (P1 Codex #60, 2ª ronda).
create or replace function private.es_creador(p_trip text, p_usuario text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.trips where id = p_trip and created_by = p_usuario
    )
$$;

-- Las policies llaman estas funciones en nombre de `authenticated`: necesita USAGE del
-- esquema y EXECUTE. Se niega a anon/public (no hay `anon` en vanilla; el revoke de
-- public basta). `private.uid()` solo lee un GUC, pero se agrupa aquí por comodidad.
grant usage on schema private to authenticated;
revoke all on all functions in schema private from public;
grant execute on all functions in schema private to authenticated;

-- 2. GRANTs mínimos del rol `authenticated` sobre los datos ---------------------
-- RLS se aplica ENCIMA de los grants: sin grant, `permission denied` antes de evaluar
-- policies. Con grant + policies, el filtro real es la policy. (El rol de CONEXIÓN de
-- la app es OTRO — un rol propio sin BYPASSRLS, miembro de `authenticated`; su GRANT y
-- config son un gate de entorno para Andrea, ver ADR-0030 §Consecuencias.)
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- 3. ENABLE RLS + policies por tabla -------------------------------------------
-- Convención: policies `to authenticated`. El rol de migración (dueño de las tablas)
-- y cualquier superusuario siguen haciendo bypass —por eso los tests de integración
-- existentes, que conectan como `postgres`, no se ven afectados—; la barrera aplica a
-- quien asuma `authenticated`.

-- 3.1 trips: bootstrap. El creador inserta su propio viaje (aún no hay membresía);
-- luego solo los miembros lo ven/editan y solo el owner lo borra.
alter table trips enable row level security;
drop policy if exists trips_select on trips;
drop policy if exists trips_insert on trips;
drop policy if exists trips_update on trips;
drop policy if exists trips_delete on trips;
create policy trips_select on trips for select to authenticated
    using (private.es_miembro(id, private.uid()));
create policy trips_insert on trips for insert to authenticated
    with check (created_by = private.uid());
create policy trips_update on trips for update to authenticated
    using (private.es_miembro(id, private.uid()))
    with check (private.es_miembro(id, private.uid()));
create policy trips_delete on trips for delete to authenticated
    using (private.rol_en_viaje(id, private.uid()) = 'owner');

-- 3.2 trip_members: bootstrap. Uno se añade a sí mismo (self-join por invitación) o lo
-- gestiona el owner; el owner o el propio miembro pueden modificar/borrar (expulsión /
-- salida). es_miembro/rol_en_viaje son security definer -> sin recursión sobre esta tabla.
alter table trip_members enable row level security;
drop policy if exists trip_members_select on trip_members;
drop policy if exists trip_members_insert on trip_members;
drop policy if exists trip_members_update on trip_members;
drop policy if exists trip_members_delete on trip_members;
create policy trip_members_select on trip_members for select to authenticated
    using (private.es_miembro(trip_id, private.uid()));
-- P1 Codex #60: el self-insert NO puede ser incondicional. Antes `member_id = uid()`
-- permitía a cualquiera que supiera el trip_id autoañadirse con CUALQUIER rol (incluido
-- owner) sin invitación, y pasar toda la RLS por-viaje. Ahora tres ramas acotadas:
create policy trip_members_insert on trip_members for insert to authenticated
    with check (
        -- 1) Unión por invitación (defensa en profundidad de unirsePorCodigo, que valida el
        --    código concreto en la capa app): como member y con invitación vigente.
        (member_id = private.uid() and role = 'member'
            and private.hay_invitacion_valida(trip_id))
        -- 2) Bootstrap de creación: el CREADOR registrado (trips.created_by) se inserta como
        --    owner cuando el viaje aún no tiene ningún miembro. Sin el check de creador,
        --    cualquiera con el trip_id se apropiaría de un viaje sin miembros (P1 Codex #60).
        or (member_id = private.uid() and role = 'owner'
            and private.es_creador(trip_id, private.uid())
            and not private.viaje_tiene_miembros(trip_id))
        -- 3) El owner gestiona altas de terceros.
        or private.rol_en_viaje(trip_id, private.uid()) = 'owner');
-- P1 Codex #60 (2ª ronda): un self-update NO puede escalar rol ni mover la fila. El
-- `role` NUEVO debe IGUALAR el rol actual del miembro (rol_en_viaje lee el estado
-- comprometido), lo que bloquea member->owner; y como rol_en_viaje se evalúa sobre el
-- trip_id/member NUEVOS, cambiar trip_id o member_id da null != role -> rechazo. Así el
-- miembro solo puede tocar campos no privilegiados (p.ej. left_at para salir). El owner
-- (rama aparte) sí gestiona roles de terceros.
create policy trip_members_update on trip_members for update to authenticated
    using (member_id = private.uid()
           or private.rol_en_viaje(trip_id, private.uid()) = 'owner')
    with check ((member_id = private.uid()
                 and role = private.rol_en_viaje(trip_id, private.uid()))
                or private.rol_en_viaje(trip_id, private.uid()) = 'owner');
create policy trip_members_delete on trip_members for delete to authenticated
    using (member_id = private.uid()
           or private.rol_en_viaje(trip_id, private.uid()) = 'owner');

-- 3.3 trip_invites: solo miembros del viaje gestionan/ven las invitaciones.
alter table trip_invites enable row level security;
drop policy if exists trip_invites_all on trip_invites;
create policy trip_invites_all on trip_invites for all to authenticated
    using (private.es_miembro(trip_id, private.uid()))
    with check (private.es_miembro(trip_id, private.uid()));

-- 3.4 Tablas por-viaje con trip_id directo: barrera de membresía uniforme (SELECT +
-- INSERT + UPDATE + DELETE). El ownership fino (quién edita/borra qué) es capa 1.
alter table expenses enable row level security;
drop policy if exists expenses_all on expenses;
create policy expenses_all on expenses for all to authenticated
    using (private.es_miembro(trip_id, private.uid()))
    with check (private.es_miembro(trip_id, private.uid()));

alter table settlements enable row level security;
drop policy if exists settlements_all on settlements;
create policy settlements_all on settlements for all to authenticated
    using (private.es_miembro(trip_id, private.uid()))
    with check (private.es_miembro(trip_id, private.uid()));

alter table polls enable row level security;
drop policy if exists polls_all on polls;
create policy polls_all on polls for all to authenticated
    using (private.es_miembro(trip_id, private.uid()))
    with check (private.es_miembro(trip_id, private.uid()));

alter table messages enable row level security;
drop policy if exists messages_all on messages;
create policy messages_all on messages for all to authenticated
    using (private.es_miembro(trip_id, private.uid()))
    with check (private.es_miembro(trip_id, private.uid()));

alter table itinerary_items enable row level security;
drop policy if exists itinerary_items_all on itinerary_items;
create policy itinerary_items_all on itinerary_items for all to authenticated
    using (private.es_miembro(trip_id, private.uid()))
    with check (private.es_miembro(trip_id, private.uid()));

alter table photos enable row level security;
drop policy if exists photos_all on photos;
create policy photos_all on photos for all to authenticated
    using (private.es_miembro(trip_id, private.uid()))
    with check (private.es_miembro(trip_id, private.uid()));

alter table itinerary_reservations enable row level security;
drop policy if exists itinerary_reservations_all on itinerary_reservations;
create policy itinerary_reservations_all on itinerary_reservations for all to authenticated
    using (private.es_miembro(trip_id, private.uid()))
    with check (private.es_miembro(trip_id, private.uid()));

-- 3.5 Tablas-hija (sin trip_id propio): membresía resuelta vía el padre.
alter table expense_shares enable row level security;
drop policy if exists expense_shares_all on expense_shares;
create policy expense_shares_all on expense_shares for all to authenticated
    using (private.es_miembro_de_gasto(expense_id, private.uid()))
    with check (private.es_miembro_de_gasto(expense_id, private.uid()));

alter table expense_revisions enable row level security;
drop policy if exists expense_revisions_all on expense_revisions;
create policy expense_revisions_all on expense_revisions for all to authenticated
    using (private.es_miembro_de_gasto(expense_id, private.uid()))
    with check (private.es_miembro_de_gasto(expense_id, private.uid()));

alter table poll_votes enable row level security;
drop policy if exists poll_votes_all on poll_votes;
create policy poll_votes_all on poll_votes for all to authenticated
    using (private.es_miembro_de_poll(poll_id, private.uid()))
    with check (private.es_miembro_de_poll(poll_id, private.uid()));

alter table itinerary_reservation_members enable row level security;
drop policy if exists itinerary_reservation_members_all on itinerary_reservation_members;
create policy itinerary_reservation_members_all on itinerary_reservation_members for all to authenticated
    using (private.es_miembro_de_reserva(activity_id, private.uid()))
    with check (private.es_miembro_de_reserva(activity_id, private.uid()));

alter table itinerary_reservation_confirmations enable row level security;
drop policy if exists itinerary_reservation_confirmations_all on itinerary_reservation_confirmations;
create policy itinerary_reservation_confirmations_all on itinerary_reservation_confirmations for all to authenticated
    using (private.es_miembro_de_reserva(activity_id, private.uid()))
    with check (private.es_miembro_de_reserva(activity_id, private.uid()));

-- 3.6 Tablas por-USUARIO (no por-viaje): idempotencia + dead-letters. Cada usuario solo
-- ve/escribe SUS filas. El servidor las escribe en nombre del actor (user_id = actor),
-- y el cliente las sincroniza de vuelta (ADR-0012 §4).
alter table idempotency_keys enable row level security;
drop policy if exists idempotency_keys_all on idempotency_keys;
create policy idempotency_keys_all on idempotency_keys for all to authenticated
    using (user_id = private.uid())
    with check (user_id = private.uid());

alter table write_rejections enable row level security;
drop policy if exists write_rejections_all on write_rejections;
create policy write_rejections_all on write_rejections for all to authenticated
    using (user_id = private.uid())
    with check (user_id = private.uid());

alter table write_conflicts enable row level security;
drop policy if exists write_conflicts_all on write_conflicts;
create policy write_conflicts_all on write_conflicts for all to authenticated
    using (user_id = private.uid())
    with check (user_id = private.uid());
