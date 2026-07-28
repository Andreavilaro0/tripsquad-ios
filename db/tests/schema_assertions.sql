-- Gate G3 + dedupe estructural (ADR-0015 §8). Se ejecuta tras aplicar las
-- migraciones contra un Postgres real. Cada assert que falle aborta con error.
--
-- Uso: psql ... -v ON_ERROR_STOP=1 -f schema_assertions.sql

\set ON_ERROR_STOP on

do $$
declare
    malas text;
begin
    -- (G3) TODA columna de dinero debe ser bigint. Buscamos columnas de importe
    -- (amount_*, *_minor) que NO sean bigint: numeric, double o int4 serían un fallo.
    select string_agg(table_name || '.' || column_name || ' (' || data_type || ')', ', ')
      into malas
      from information_schema.columns
     where table_schema = 'public'
       and (column_name like 'amount\_%' or column_name like '%\_minor')
       and data_type <> 'bigint';
    if malas is not null then
        raise exception 'G3 VIOLADO: columnas de dinero que no son bigint: %', malas;
    end if;

    -- fx_rate SÍ debe ser numeric (es una tasa, no dinero-a-sumar).
    if not exists (
        select 1 from information_schema.columns
         where table_schema='public' and table_name='expenses'
           and column_name='fx_rate' and data_type='numeric'
    ) then
        raise exception 'expenses.fx_rate debe ser numeric (es una tasa)';
    end if;

    -- Dedupe estructural: la PK de expenses es el id de cliente.
    if not exists (
        select 1 from information_schema.table_constraints
         where table_schema='public' and table_name='expenses' and constraint_type='PRIMARY KEY'
    ) then
        raise exception 'expenses necesita PRIMARY KEY (dedupe estructural)';
    end if;

    -- Dedupe de liquidaciones incluye transfer_index (ADR-0015 §5).
    if not exists (
        select 1 from pg_indexes
         where schemaname='public' and tablename='settlements'
           and indexdef like '%transfer_index%'
    ) then
        raise exception 'settlements necesita unique con transfer_index (ADR-0015 §5)';
    end if;

    -- Tabla de idempotencia con su PK compuesta (ADR-0012 §2).
    if not exists (
        select 1 from information_schema.table_constraints
         where table_schema='public' and table_name='idempotency_keys' and constraint_type='PRIMARY KEY'
    ) then
        raise exception 'idempotency_keys necesita PRIMARY KEY (user_id, idempotency_key)';
    end if;

    -- Dead-letters presentes (ADR-0012 §4, ADR-0015 §2).
    perform 1 from information_schema.tables where table_schema='public' and table_name='write_rejections';
    if not found then raise exception 'falta write_rejections'; end if;
    perform 1 from information_schema.tables where table_schema='public' and table_name='write_conflicts';
    if not found then raise exception 'falta write_conflicts'; end if;

    -- Reparto exacto: las cuotas van en tabla tipada, no en jsonb (hallazgo de
    -- Codex). El gate G3 de arriba ya cubre expense_shares.amount_minor porque es
    -- un `%_minor`; aquí solo confirmamos que la tabla existe.
    perform 1 from information_schema.tables where table_schema='public' and table_name='expense_shares';
    if not found then raise exception 'falta expense_shares (cuotas exactas tipadas)'; end if;

    raise notice 'OK: G3 + dedupe estructural + dead-letters + cuotas exactas tipadas verificados';
end $$;

-- Prueba funcional del dedupe estructural: insertar el mismo gasto dos veces con
-- ON CONFLICT DO NOTHING deja UNA sola fila.
insert into trips (id, currency_reference) values ('t1', 'EUR') on conflict do nothing;
insert into trip_members (trip_id, member_id) values ('t1','m1') on conflict do nothing;

insert into expenses (id, trip_id, paid_by, amount_reference, amount_original, currency_original, split_kind, split, etag)
values ('g1','t1','m1', 1000, 1000, 'EUR', 'equal', '{"among":["m1"]}', 'v1')
on conflict (id) do nothing;
-- Reintento del MISMO id: no duplica.
insert into expenses (id, trip_id, paid_by, amount_reference, amount_original, currency_original, split_kind, split, etag)
values ('g1','t1','m1', 1000, 1000, 'EUR', 'equal', '{"among":["m1"]}', 'v1')
on conflict (id) do nothing;

do $$
declare n int;
begin
    select count(*) into n from expenses where id='g1';
    if n <> 1 then raise exception 'dedupe estructural FALLÓ: % filas para g1', n; end if;
    raise notice 'OK: dedupe estructural funciona (1 fila para g1 tras 2 inserts)';
end $$;

-- Cuotas exactas tipadas: se insertan con amount_minor bigint y no-negativo. Una
-- cuota negativa debe ser rechazada por el check.
insert into expense_shares (expense_id, member_id, amount_minor) values ('g1','m1', 1000)
on conflict do nothing;
-- m2 debe ser miembro de t1 para que este test AÍSLE el rechazo por importe negativo:
-- desde 0012 el trigger de membresía se dispara antes que el CHECK, así que un
-- member_id no-miembro daría foreign_key_violation en vez de check_violation.
insert into trip_members (trip_id, member_id) values ('t1','m2') on conflict do nothing;
do $$
begin
    begin
        insert into expense_shares (expense_id, member_id, amount_minor) values ('g1','m2', -5);
        raise exception 'una cuota negativa NO debería aceptarse';
    exception when check_violation then
        raise notice 'OK: expense_shares rechaza cuotas negativas';
    end;
end $$;

-- Defensa en profundidad de membresía (bead epb, migración 0012 + 0013) --------------
--
-- El FK compuesto de expenses.paid_by debe existir y estar VALIDADO (0013 corre el
-- VALIDATE), y el trigger de membresía de expense_shares debe existir.
do $$
begin
    if not exists (
        select 1 from pg_constraint
         where conname = 'fk_expenses_paid_by_miembro'
           and contype = 'f'
           and convalidated = true
    ) then
        raise exception 'falta el FK validado fk_expenses_paid_by_miembro (expenses.paid_by -> trip_members)';
    end if;

    if not exists (
        select 1 from pg_trigger
         where tgname = 'trg_expense_shares_member_es_miembro'
           and not tgisinternal
    ) then
        raise exception 'falta el trigger trg_expense_shares_member_es_miembro (membresía de expense_shares)';
    end if;

    raise notice 'OK: FK de paid_by validado + trigger de membresía de expense_shares presentes';
end $$;

-- Funcional (positivo): un share de un miembro real (m1) se acepta -> ya insertado
-- arriba (g1,m1) sin error, lo que prueba que el trigger no rechaza a los miembros.

-- Funcional (negativo, expense_shares): un share cuyo member_id NO es miembro del
-- viaje del gasto debe ser rechazado por el trigger.
do $$
begin
    begin
        insert into expense_shares (expense_id, member_id, amount_minor) values ('g1','fantasma', 500);
        raise exception 'un share de un NO-miembro NO debería aceptarse';
    exception when foreign_key_violation then
        raise notice 'OK: expense_shares rechaza member_id que no es miembro del viaje';
    end;
end $$;

-- Funcional (negativo, expenses.paid_by): un gasto cuyo paid_by NO es miembro del
-- viaje debe ser rechazado por el FK compuesto (aplica a filas nuevas aun con NOT
-- VALID; aquí además ya está validado por 0013).
do $$
begin
    begin
        insert into expenses (id, trip_id, paid_by, amount_reference, amount_original, currency_original, split_kind, split, etag)
        values ('g_bad','t1','fantasma', 1000, 1000, 'EUR', 'equal', '{"among":["m1"]}', 'v1');
        raise exception 'un gasto con paid_by NO-miembro NO debería aceptarse';
    exception when foreign_key_violation then
        raise notice 'OK: expenses rechaza paid_by que no es miembro del viaje';
    end;
end $$;

-- Funcional (positivo, miembro que ya salió): un miembro con left_at != null sigue
-- siendo miembro del viaje y sus shares deben aceptarse (membresía = existencia).
insert into trip_members (trip_id, member_id, left_at) values ('t1','m_ex', now()) on conflict do nothing;
insert into expense_shares (expense_id, member_id, amount_minor) values ('g1','m_ex', 250) on conflict do nothing;
do $$
declare n int;
begin
    select count(*) into n from expense_shares where expense_id='g1' and member_id='m_ex';
    if n <> 1 then raise exception 'un miembro que salió del viaje (left_at) debería poder tener shares'; end if;
    raise notice 'OK: membresía = existencia (un miembro con left_at sigue siendo válido)';
end $$;
