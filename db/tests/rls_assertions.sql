-- Test de contrato de la RLS (ADR-0030, bead 5n3). Demuestra que, al asumir el rol
-- `authenticated` + claim `sub` (mecanismo A+B), un usuario NO-MIEMBRO no puede
-- leer ni escribir filas de un viaje ajeno, aunque el rol tenga GRANT sobre la tabla.
--
-- Se ejecuta como `postgres` (superusuario) TRAS aplicar las migraciones; el
-- `set local role authenticated` de cada transacción hace que la RLS SÍ se evalúe
-- (postgres bypassa RLS solo mientras es postgres; al asumir authenticated, no).
--
-- Uso: psql ... -v ON_ERROR_STOP=1 -f rls_assertions.sql

\set ON_ERROR_STOP on

-- 0. El rol authenticated NO debe tener BYPASSRLS (si no, las policies ni se evalúan).
do $$
begin
    if (select rolbypassrls from pg_roles where rolname = 'authenticated') then
        raise exception 'RLS ROTA: el rol authenticated tiene BYPASSRLS';
    end if;
end $$;

-- 1. Semilla (como postgres, bypass RLS): viaje T con Ana (owner) e Iván, y un gasto de Ana.
insert into trips (id, currency_reference, name, base_currency, created_by)
    values ('rls_t', 'EUR', 'RLS test', 'EUR', 'ana') on conflict (id) do nothing;
insert into trip_members (trip_id, member_id, role) values ('rls_t', 'ana', 'owner')
    on conflict (trip_id, member_id) do nothing;
insert into trip_members (trip_id, member_id, role) values ('rls_t', 'ivan', 'member')
    on conflict (trip_id, member_id) do nothing;
insert into expenses (id, trip_id, paid_by, amount_reference, amount_original,
        currency_original, split_kind, split, etag)
    values ('rls_g', 'rls_t', 'ana', 1000, 1000, 'EUR', 'equal', '{"among":["ana"]}', 'v1')
    on conflict (id) do nothing;

-- 2. NO-MIEMBRO (sara): no ve el gasto.
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"sara","role":"authenticated"}', true);
    do $$
    begin
        if exists (select 1 from expenses where id = 'rls_g') then
            raise exception 'RLS FUGA: no-miembro (sara) VE el gasto rls_g';
        end if;
        if exists (select 1 from trips where id = 'rls_t') then
            raise exception 'RLS FUGA: no-miembro (sara) VE el viaje rls_t';
        end if;
    end $$;
commit;

-- 3. NO-MIEMBRO (sara): no puede escribir (UPDATE afecta 0 filas; INSERT viola la policy).
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"sara","role":"authenticated"}', true);
    do $$
    declare afectadas int;
    begin
        update expenses set amount_reference = 999 where id = 'rls_g';
        get diagnostics afectadas = row_count;
        if afectadas <> 0 then
            raise exception 'RLS FUGA: sara pudo UPDATE % filas del gasto ajeno', afectadas;
        end if;

        begin
            insert into expenses (id, trip_id, paid_by, amount_reference, amount_original,
                    currency_original, split_kind, split, etag)
                values ('rls_g2', 'rls_t', 'sara', 500, 500, 'EUR', 'equal', '{"among":["sara"]}', 'v1');
            raise exception 'RLS FUGA: sara pudo INSERT en el viaje ajeno';
        exception
            when insufficient_privilege then
                null;  -- 42501: new row violates row-level security policy -> esperado
        end;
    end $$;
rollback;

-- 4. MIEMBRO (ivan): SÍ ve el gasto (la barrera es de membresía; el ownership fino es capa 1).
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"ivan","role":"authenticated"}', true);
    do $$
    begin
        if not exists (select 1 from expenses where id = 'rls_g') then
            raise exception 'RLS FALSO NEGATIVO: miembro (ivan) NO ve el gasto rls_g';
        end if;
    end $$;
commit;

-- 5. MIEMBRO (ana): puede escribir en su viaje.
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"ana","role":"authenticated"}', true);
    do $$
    declare afectadas int;
    begin
        update expenses set amount_reference = 1500 where id = 'rls_g';
        get diagnostics afectadas = row_count;
        if afectadas <> 1 then
            raise exception 'RLS FALSO POSITIVO: miembro (ana) NO pudo UPDATE su gasto (% filas)', afectadas;
        end if;
    end $$;
rollback;

-- 6. Sin claim (sub NULL): fallo-seguro, no ve nada.
begin;
    set local role authenticated;
    do $$
    begin
        if exists (select 1 from expenses where id = 'rls_g') then
            raise exception 'RLS FUGA: sin claim sub la policy debería negar y no lo hace';
        end if;
    end $$;
commit;

-- 7. P1 Codex #60: un no-miembro (sara) NO puede autoañadirse a un viaje ajeno sin
--    invitación vigente — ni como owner (escalada) ni como member. La capa app valida el
--    código concreto (unirsePorCodigo); esto es la barrera de defensa en profundidad.
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"sara","role":"authenticated"}', true);
    do $$
    begin
        begin
            insert into trip_members (trip_id, member_id, role) values ('rls_t', 'sara', 'owner');
            raise exception 'RLS HUECO: sara se autoañadió como OWNER sin invitación';
        exception when insufficient_privilege then null;   -- esperado: RLS lo corta
        end;
        begin
            insert into trip_members (trip_id, member_id, role) values ('rls_t', 'sara', 'member');
            raise exception 'RLS HUECO: sara se autoañadió como member sin invitación vigente';
        exception when insufficient_privilege then null;   -- esperado: no hay invite vigente
        end;
    end $$;
rollback;

-- 8. P1 Codex #60 (2ª ronda): en un viaje SIN miembros, el bootstrap-owner solo lo puede
--    hacer el CREADOR (trips.created_by), no cualquiera que sepa el trip_id.
insert into trips (id, currency_reference, name, base_currency, created_by)
    values ('rls_empty', 'EUR', 'sin miembros', 'EUR', 'ana') on conflict (id) do nothing;
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"sara"}', true);
    do $$
    begin
        begin
            insert into trip_members (trip_id, member_id, role) values ('rls_empty', 'sara', 'owner');
            raise exception 'RLS HUECO: no-creador (sara) se apropió de un viaje sin miembros';
        exception when insufficient_privilege then null;   -- esperado: no es el creador
        end;
    end $$;
rollback;
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"ana"}', true);
    do $$
    declare afectadas int;
    begin
        insert into trip_members (trip_id, member_id, role) values ('rls_empty', 'ana', 'owner');
        get diagnostics afectadas = row_count;
        if afectadas <> 1 then
            raise exception 'RLS FALSO POSITIVO: el creador (ana) no pudo bootstrap-owner (% filas)', afectadas;
        end if;
    end $$;
rollback;

-- 9. P1 Codex #60 (2ª ronda): un miembro (ivan) NO puede auto-escalar su rol a owner.
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"ivan"}', true);
    do $$
    begin
        begin
            update trip_members set role = 'owner' where trip_id = 'rls_t' and member_id = 'ivan';
            if exists (select 1 from public.trip_members where trip_id = 'rls_t' and member_id = 'ivan' and role = 'owner') then
                raise exception 'RLS HUECO: ivan se auto-escaló a owner';
            end if;
        exception when insufficient_privilege then null;   -- esperado: el role nuevo != role actual
        end;
    end $$;
rollback;

-- 9b. Un self-update legítimo (salir: fijar left_at, sin tocar el rol) SÍ se permite.
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"ivan"}', true);
    do $$
    declare afectadas int;
    begin
        update trip_members set left_at = now() where trip_id = 'rls_t' and member_id = 'ivan';
        get diagnostics afectadas = row_count;
        if afectadas <> 1 then
            raise exception 'RLS FALSO POSITIVO: ivan no pudo salir (self-update de left_at, % filas)', afectadas;
        end if;
    end $$;
rollback;

-- 10. Enrutado RLS (bead RLS-enrutado): una LECTURA por-usuario de una tabla por-viaje
--     (messages, ahora enrutada por `enTransaccionConRolActual`) se corta a un no-miembro y
--     se permite a un miembro — el mismo camino A+B que ahora recorren TODAS las lecturas.
insert into messages (trip_id, member_id, body, created_at)
    values ('rls_t', 'ana', 'hola squad', now()) on conflict do nothing;
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"sara"}', true);
    do $$
    begin
        if exists (select 1 from messages where trip_id = 'rls_t') then
            raise exception 'RLS FUGA: no-miembro (sara) VE mensajes del viaje ajeno (lectura enrutada)';
        end if;
    end $$;
commit;
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"ivan"}', true);
    do $$
    begin
        if not exists (select 1 from messages where trip_id = 'rls_t') then
            raise exception 'RLS FALSO NEGATIVO: miembro (ivan) NO ve mensajes de su viaje (lectura enrutada)';
        end if;
    end $$;
commit;

-- 11. Operación de SISTEMA sin actor: `private.caducar_settlements_pendientes` (security
--     definer, 0015) materializa como `cancelled` los `pending` vencidos CROSS-VIAJE —
--     algo que ningún usuario individual puede hacer bajo la RLS. Se ejecuta sin rol de
--     usuario (como el cron) y devuelve el conteo.
insert into settlements
        (id, trip_id, settlement_id, from_member, to_member, transfer_index, amount_minor, status, created_by, expires_at)
    values ('rls_sett', 'rls_t', 'sett-1', 'ana', 'ivan', 0, 100, 'pending', 'ana', now() - interval '1 day')
    on conflict (id) do nothing;
do $$
declare n integer;
begin
    n := private.caducar_settlements_pendientes(now());
    if n < 1 then
        raise exception 'SISTEMA: caducar_settlements_pendientes no caducó el pending vencido (n=%)', n;
    end if;
    if not exists (select 1 from settlements where id = 'rls_sett' and status = 'cancelled') then
        raise exception 'SISTEMA: el settlement vencido no quedó cancelled tras el barrido';
    end if;
end $$;

-- 12. `private.invitacion_por_codigo` (security definer, 0015): resuelve el código para
--     quien AÚN no es miembro (sara), aunque la RLS de `trip_invites` le oculte el código
--     por la vía normal. Es el seam por el que `unirsePorCodigo` obtiene el trip_id sin
--     filtrarle nada de más.
insert into trip_invites (code, trip_id, created_by, expires_at)
    values ('rls-code', 'rls_t', 'ana', now() + interval '7 days') on conflict (code) do nothing;
begin;
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub":"sara"}', true);
    do $$
    declare v_trip text; v_estado text; v_activo boolean;
    begin
        select trip_id, estado, es_activo
            into v_trip, v_estado, v_activo
            from private.invitacion_por_codigo('rls-code', now());
        if v_estado <> 'ok' or v_trip is distinct from 'rls_t' then
            raise exception 'SECDEF: invitacion_por_codigo no resolvió el code para un no-miembro (trip=%, estado=%)', v_trip, v_estado;
        end if;
        if v_activo then
            raise exception 'SECDEF: invitacion_por_codigo marca al no-miembro (sara) como ya activo';
        end if;
        -- Y por la vía NORMAL (RLS) sara NO ve la invitación: la SECDEF es imprescindible.
        if exists (select 1 from trip_invites where code = 'rls-code') then
            raise exception 'RLS FUGA: no-miembro (sara) VE trip_invites directamente (sin la SECDEF)';
        end if;
    end $$;
commit;

select 'OK: RLS por-usuario (A+B, ADR-0030) verificada — no-miembro cortado (incl. self-join sin invitación y lectura enrutada), bootstrap solo-creador, sin auto-escalada de rol, y operaciones de sistema (caducar/invitacion) por security definer' as resultado;
