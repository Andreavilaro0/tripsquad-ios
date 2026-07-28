-- Migración 0015 — funciones `security definer` para las operaciones de SISTEMA que NO
-- tienen un actor-usuario y por eso NO pueden ir por el enrutado RLS por task-local
-- (bead RLS-enrutado, extiende ADR-0030). El resto de lecturas/escrituras por-usuario de
-- los repos pasan por `enTransaccionConRolActual` (SET LOCAL role=authenticated + claim
-- sub=actor) y la RLS de 0014 las filtra por membresía. Estas dos operaciones no encajan
-- ahí:
--
--   1) Caducar settlements pendientes (cron, CasosDeUsoSettle.caducarPendientes): un
--      barrido CROSS-VIAJE que ningún usuario individual está autorizado a hacer bajo la
--      RLS (un usuario solo toca sus viajes). Lo ejecuta el sistema, sin actor.
--
--   2) Resolver un código de invitación (unirsePorCodigo): quien entra AÚN no es miembro
--      del viaje, así que la RLS de `trip_invites`/`trips`/`trip_members` (todas exigen
--      `private.es_miembro`) le ocultaría el código, el viaje y el conteo de miembros. La
--      función resuelve esos datos de bootstrap saltándose la RLS (security definer),
--      usando `private.uid()` para las facetas del propio actor. El INSERT/reactivación de
--      la membresía SÍ lo hace el repo como el actor entrante (rama de invitación de la
--      policy `trip_members_insert`, ADR-0030 / 0014 §3.2), no aquí.
--
-- Convención idéntica a 0014: esquema `private`, `set search_path=''`, y GRANT EXECUTE a
-- `authenticated` (revocado de PUBLIC). Idempotente en re-ejecución (`create or replace`).

-- 1. Caducar settlements pendientes (sistema, sin actor) ------------------------
-- Materializa como `cancelled` los `pending` vencidos de TODOS los viajes y devuelve
-- cuántos. Misma semántica que hacía el UPDATE del repo (bead 1ea); ahora en una función
-- security definer para que el servicio pueda invocarla bajo el rol de app sin BYPASSRLS
-- y sin contexto de usuario. `resolved_by` queda NULL (lo caduca el sistema). Idempotente:
-- una 2ª pasada no encuentra ya pending vencidos.
create or replace function private.caducar_settlements_pendientes(p_ahora timestamptz)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
    v_count integer;
begin
    with upd as (
        update public.settlements
        set status = 'cancelled', resolved_at = p_ahora
        where status = 'pending' and expires_at < p_ahora
        returning 1
    )
    select count(*)::integer into v_count from upd;
    return v_count;
end;
$$;

-- 2. Resolver el código de invitación + facetas de bootstrap del join ------------
-- Devuelve, para el `p_code` dado y el actor actual (`private.uid()`), todo lo que
-- `unirsePorCodigo` necesita para DECIDIR antes de escribir, sin leer bajo RLS lo que un
-- no-miembro no puede ver:
--   · estado: 'ok' | 'invalido' (code inexistente) | 'revocado' | 'caducado'.
--   · trip_id: el viaje del código (NULL si 'invalido').
--   · closed_at: si el viaje está cerrado (sustituye al `SELECT trips ... FOR UPDATE` que
--     la RLS de `trips` bloquearía a un no-miembro).
--   · activos: nº de miembros ACTIVOS del viaje (para el tope), contado con la fila del
--     viaje bloqueada `FOR UPDATE` — serializa joins concurrentes al mismo viaje igual que
--     el `FOR UPDATE` original, cerrando la carrera del tope.
--   · existe_fila / es_activo: ¿el actor ya tiene fila en el viaje (para reactivar en vez
--     de insertar) y está activo (yaMiembro)? — su PROPIA membresía, que la RLS de
--     `trip_members` también le ocultaría si dejó el viaje (left_at != null).
-- Solo lecturas; el WRITE de la membresía lo hace el repo como el actor.
create or replace function private.invitacion_por_codigo(p_code text, p_ahora timestamptz)
returns table(
    trip_id text,
    closed_at timestamptz,
    activos integer,
    existe_fila boolean,
    es_activo boolean,
    estado text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
    v_trip text;
    v_expires timestamptz;
    v_revoked timestamptz;
    v_closed timestamptz;
    v_uid text := private.uid();
begin
    select i.trip_id, i.expires_at, i.revoked_at
        into v_trip, v_expires, v_revoked
        from public.trip_invites i
        where i.code = p_code;

    if v_trip is null then
        return query select null::text, null::timestamptz, 0, false, false, 'invalido'::text;
        return;
    end if;
    if v_revoked is not null then
        return query select v_trip, null::timestamptz, 0, false, false, 'revocado'::text;
        return;
    end if;
    -- Caducidad con el `ahora` INYECTADO por el llamante (no el reloj de la BD): determinismo
    -- en tests y consistencia si los relojes del servicio y de la BD difieren (P2 Codex #63).
    -- `<= p_ahora`: caducada EN el instante exacto de `expires_at` (P2 Codex #63), coherente
    -- con `unirse_por_invitacion` (`> p_ahora`) y con el doble en memoria (`expiresAt > ahora`).
    if v_expires <= p_ahora then
        return query select v_trip, null::timestamptz, 0, false, false, 'caducado'::text;
        return;
    end if;

    -- Bloquea la fila del viaje: los joins concurrentes al MISMO viaje se serializan aquí,
    -- así el conteo del tope y el posterior INSERT del repo son atómicos (misma protección
    -- que el `FOR UPDATE` de la versión previa). Si el viaje no existe (invitación colgada),
    -- el código es inválido.
    select t.closed_at into v_closed
        from public.trips t where t.id = v_trip for update;
    if not found then
        return query select v_trip, null::timestamptz, 0, false, false, 'invalido'::text;
        return;
    end if;

    return query select
        v_trip,
        v_closed,
        (select count(*)::integer from public.trip_members m
            where m.trip_id = v_trip and m.left_at is null),
        exists(select 1 from public.trip_members m
            where m.trip_id = v_trip and m.member_id = v_uid),
        exists(select 1 from public.trip_members m
            where m.trip_id = v_trip and m.member_id = v_uid and m.left_at is null),
        'ok'::text;
end;
$$;

-- 2b. Reactivar la membresía de un reingreso por código -------------------------
-- Cuando quien vuelve dejó el viaje (trip_members.left_at != null), `unirsePorCodigo`
-- REACTIVA su fila (left_at = null) en vez de insertar una nueva (la PK es
-- (trip_id, member_id)). Ese UPDATE NO lo puede hacer el propio usuario bajo la RLS: la
-- policy `trip_members_update` (rama self) exige role = private.rol_en_viaje(...), que
-- devuelve NULL mientras la fila está inactiva -> el WITH CHECK falla. Por eso va security
-- definer. El INSERT de un miembro NUEVO sí va como el actor (rama de invitación de
-- `trip_members_insert`); solo la reactivación necesita este seam.
--
-- Alta por invitación (nueva O reingreso), TODO con el `p_ahora` INYECTADO. Consolida el
-- INSERT de miembro nuevo y la reactivación de quien salió (P1/P2 Codex #63): ambos caminos
-- validaban la caducidad con DISTINTO reloj —el INSERT vía la policy `trip_members_insert`
-- (que llama a `hay_invitacion_valida` con `now()`), la reactivación aparte— y podían diverger
-- de `invitacion_por_codigo` (que ya validó con `p_ahora`) por desfase de reloj cerca de la
-- caducidad: un alta nueva daba violación RLS/5xx, un reingreso omitía el UPDATE en silencio.
-- Aquí ambos usan `expires_at > p_ahora`, coherente con `invitacion_por_codigo` y con el doble
-- en memoria. security definer + `unirsePorCodigo` ya validó el código: esto es la escritura.
create or replace function private.unirse_por_invitacion(p_trip text, p_usuario text, p_ahora timestamptz)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
    if not exists (
        select 1 from public.trip_invites i
        where i.trip_id = p_trip and i.revoked_at is null and i.expires_at > p_ahora
    ) then
        return;   -- sin invitación viva a `p_ahora`: no escribe (defensa en profundidad).
    end if;
    -- Reingreso: reactiva la fila del que salió (PK (trip_id, member_id)).
    update public.trip_members
        set left_at = null, joined_at = p_ahora
        where trip_id = p_trip and member_id = p_usuario and left_at is not null;
    if not found then
        -- Alta nueva.
        insert into public.trip_members (trip_id, member_id, role, joined_at)
            values (p_trip, p_usuario, 'member', p_ahora)
            on conflict (trip_id, member_id) do nothing;
    end if;
end;
$$;

-- 3. Derecho al olvido RGPD (sistema/admin, sin actor) -------------------------
-- `CasosDeUso.olvidarRevisionesDe` (bead o1v, ADR-0027): hard-delete GLOBAL de las
-- revisiones de un autor en TODOS los viajes. Es un flujo ADMINISTRATIVO de borrado de
-- cuenta, sin `tripId` ni gate de membresía: quien ejerce su derecho al olvido puede ya no
-- ser miembro de ningún viaje. Bajo la RLS de `expense_revisions`
-- (private.es_miembro_de_gasto) un DELETE por-usuario dejaría fuera justo las revisiones en
-- viajes que el usuario abandonó — RGPD incompleto. Por eso va por security definer: borra
-- TODAS las filas del autor, saltándose la RLS, y devuelve cuántas. NO toca `expenses` (el
-- gasto puede ser de otro dueño): misma semántica exacta que hacía el DELETE del repo.
create or replace function private.olvidar_revisiones_de(p_usuario text)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
    v_count integer;
begin
    with del as (
        delete from public.expense_revisions where edited_by = p_usuario
        returning 1
    )
    select count(*)::integer into v_count from del;
    return v_count;
end;
$$;

-- GRANTs: las invoca el servicio en nombre de `authenticated` (invitacion_por_codigo va
-- dentro de la transacción-con-rol; caducar_settlements_pendientes / olvidar_revisiones_de
-- las llama el sistema con un rol de app que hereda `authenticated`). Se revoca de PUBLIC.
revoke all on function private.caducar_settlements_pendientes(timestamptz) from public;
revoke all on function private.invitacion_por_codigo(text, timestamptz) from public;
revoke all on function private.unirse_por_invitacion(text, text, timestamptz) from public;
revoke all on function private.olvidar_revisiones_de(text) from public;
grant execute on function private.caducar_settlements_pendientes(timestamptz) to authenticated;
grant execute on function private.invitacion_por_codigo(text, timestamptz) to authenticated;
grant execute on function private.unirse_por_invitacion(text, text, timestamptz) to authenticated;
grant execute on function private.olvidar_revisiones_de(text) to authenticated;
