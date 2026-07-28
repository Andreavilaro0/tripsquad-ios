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

select 'OK: RLS por-usuario (A+B, ADR-0030) verificada — no-miembro cortado (incl. self-join sin invitación), miembro pasa' as resultado;
