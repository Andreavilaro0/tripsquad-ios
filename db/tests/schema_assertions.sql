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

    raise notice 'OK: G3 + dedupe estructural + dead-letters verificados';
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
