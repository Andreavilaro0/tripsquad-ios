-- Migración 0012 — defensa en profundidad: las identidades de un gasto deben ser
-- MIEMBROS del viaje (bead epb). Append-only: solo añade, no reescribe migraciones
-- previas.
--
-- CONTEXTO: en 0001_expenses.sql, `expenses.paid_by` y `expense_shares.member_id`
-- son `text` sueltos, sin ninguna garantía en BD de que apunten a un miembro real
-- del viaje (`trip_members`, clavada por `(trip_id, member_id)`). La capa de
-- aplicación (packages/TripSquadExpenses) ya valida la membresía antes de escribir;
-- esta migración es la SEGUNDA capa —la defensa en BD—, con el mismo criterio de
-- "defensa en BD" de 0006_chat.sql y 0011_limites_texto.sql: si un bug de dominio o
-- una escritura directa se saltara la validación, la BD rechaza el share/gasto.
--
-- POR QUÉ DOS MECANISMOS DISTINTOS (declarativo vs trigger) — no es incoherencia,
-- es lo que permite cada tabla:
--
--   1) `expenses.paid_by`: la fila YA lleva `trip_id`, así que la clave de
--      `trip_members (trip_id, member_id)` se puede referenciar con una FK COMPUESTA
--      declarativa nativa `(trip_id, paid_by) -> trip_members (trip_id, member_id)`.
--      Es lo más idiomático de Postgres: la impone el motor, es barata y usa el PK
--      de `trip_members` como índice. Se añade NOT VALID (ver más abajo).
--
--   2) `expense_shares.member_id`: la tabla NO tiene `trip_id` (su PK es
--      `(expense_id, member_id)`). Una FK compuesta declarativa exigiría denormalizar
--      un `trip_id` en `expense_shares` + backfill + mantenerlo sincronizado con el
--      gasto padre — invasivo y contrario al principio conservador de esta fase. En su
--      lugar, un TRIGGER resuelve el `trip_id` del gasto padre (`expenses`) y exige que
--      `(trip_id, member_id)` exista en `trip_members`. Un trigger BEFORE INSERT/UPDATE
--      solo se dispara en escrituras NUEVAS, así que —igual que una FK NOT VALID sin
--      validar— protege las filas nuevas sin tocar el histórico. (Alternativa
--      documentada para Andrea: denormalizar `trip_id` y usar FK compuesta también aquí;
--      queda como follow-up si algún día se quiere uniformar, ver más abajo.)
--
-- POR QUÉ "NOT VALID" + VALIDATE EN MIGRACIÓN SEPARADA (0013): un FK directo (validado
-- al vuelo) escanea TODA la tabla al crearse y FALLA el arranque si existe una sola
-- fila histórica que lo viole. `ADD CONSTRAINT ... NOT VALID` impone la regla a las
-- filas NUEVAS de inmediato SIN escanear las viejas, así que la migración nunca rompe
-- el boot aunque hubiera datos sucios. La validación del histórico (que SÍ escanea y
-- puede fallar) se aísla en 0013_validar_fk_paid_by.sql, para poder desplegarla cuando
-- se sepa que los datos están limpios. Hoy las tablas de la Fase S están vacías en
-- todos los entornos, así que 0013 es un no-op; el patrón queda por robustez.
--
-- MEMBRESÍA = EXISTENCIA, NO "ACTIVO": comprobamos que la fila exista en
-- `trip_members` con ESE `(trip_id, member_id)`, SIN mirar `left_at`. Un miembro que ya
-- salió del viaje (`left_at not null`) sigue siendo un miembro conocido del viaje y
-- puede seguir debiendo/cobrando en gastos anteriores a su salida; exigir `left_at is
-- null` rechazaría shares legítimos. "Referenciar a un miembro del viaje" = existir en
-- `trip_members`, ni más ni menos.
--
-- IDEMPOTENCIA: re-ejecutar esta migración es un no-op. El FK se envuelve en un `DO`
-- que mira `pg_constraint` antes de añadirlo (mismo patrón que 0011); la función usa
-- `create or replace`; el trigger usa `create or replace trigger` (Postgres >= 14).

-- --- 1) expenses.paid_by -> trip_members (FK compuesta declarativa, NOT VALID) ---

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'fk_expenses_paid_by_miembro') then
        alter table expenses
            add constraint fk_expenses_paid_by_miembro
            foreign key (trip_id, paid_by)
            references trip_members (trip_id, member_id)
            not valid;
    end if;
end $$;

-- --- 2) expense_shares.member_id -> miembro del viaje del gasto (trigger) ---
--
-- El trigger resuelve el viaje a través del gasto padre. Si el gasto no existiera, el
-- FK `expense_shares.expense_id -> expenses.id` (0001) ya lo rechaza; aquí solo
-- validamos la membresía. Se dispara al INSERT y al UPDATE de las columnas que definen
-- la identidad/pertenencia (`member_id`, `expense_id`).

create or replace function tsq_expense_share_member_es_miembro()
returns trigger
language plpgsql
as $$
declare
    v_trip_id text;
begin
    select trip_id into v_trip_id from expenses where id = new.expense_id;

    if v_trip_id is not null
       and not exists (
           select 1 from trip_members tm
            where tm.trip_id = v_trip_id
              and tm.member_id = new.member_id
       )
    then
        raise exception
            'expense_shares.member_id % no es miembro del viaje % (defensa en profundidad, bead epb)',
            new.member_id, v_trip_id
            using errcode = 'foreign_key_violation';
    end if;

    return new;
end;
$$;

create or replace trigger trg_expense_shares_member_es_miembro
    before insert or update of member_id, expense_id on expense_shares
    for each row
    execute function tsq_expense_share_member_es_miembro();
