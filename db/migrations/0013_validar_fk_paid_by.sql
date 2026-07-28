-- Migración 0013 — validar el FK `fk_expenses_paid_by_miembro` contra el histórico
-- (bead epb). Append-only. Par de 0012_membresia_gastos_defensa.sql.
--
-- 0012 añadió el FK `(trip_id, paid_by) -> trip_members` como NOT VALID: impone la
-- regla a las filas NUEVAS pero NO escanea las viejas. Esta migración ejecuta el
-- VALIDATE CONSTRAINT, que SÍ escanea las filas existentes y falla si alguna las viola.
-- Va aparte a propósito (ver el razonamiento largo en 0012): así 0012 nunca rompe el
-- arranque por datos históricos, y el escaneo que sí puede fallar se despliega cuando se
-- sabe que los datos están limpios. Hoy las tablas de la Fase S están vacías en todos
-- los entornos, así que este VALIDATE es un no-op.
--
-- IDEMPOTENCIA: `VALIDATE CONSTRAINT` sobre un FK ya validado es un no-op en Postgres,
-- pero envolvemos en un `DO` que solo lo ejecuta si el constraint existe y aún NO está
-- validado (`pg_constraint.convalidated = false`), para no depender de ese detalle y
-- dejar claro el intento.

do $$
begin
    if exists (
        select 1 from pg_constraint
         where conname = 'fk_expenses_paid_by_miembro'
           and convalidated = false
    ) then
        alter table expenses validate constraint fk_expenses_paid_by_miembro;
    end if;
end $$;
