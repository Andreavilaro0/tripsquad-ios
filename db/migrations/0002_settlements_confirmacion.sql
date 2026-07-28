-- ADR-0017: :settle pasa a pendiente + confirmación. La dedupe estructural se apoya en la
-- UNIQUE (trip_id, settlement_id, from_member, to_member, transfer_index) ya existente en
-- 0001 (que SÍ incluye trip_id), no en el id. El id pasa a ser un surrogate (UUID cliente).
alter table settlements
    add column status       text        not null default 'pending'
        check (status in ('pending','confirmed','rejected','cancelled')),
    add column created_by   text        not null default '',
    add column expires_at   timestamptz not null default now() + interval '30 days',
    add column resolved_by  text,
    add column resolved_at  timestamptz,
    add column reject_reason text;

-- `round` deja de pasarse a mano (fix E): default 0.
alter table settlements alter column round set default 0;

-- NOTA (Codex P1): la tabla `settlements` está VACÍA en todos los entornos (nunca hubo
-- endpoint que escribiera antes de ADR-0017), así que el `default ''` de `created_by` no
-- afecta a filas reales; toda fila nueva la escribe `crear` con un `created_by` válido. La
-- capa de dominio, además, rechaza transicionar cualquier fila cuyo `created_by ∉ {from,to}`.

-- Índices para las lecturas por estado (aviso de pendientes, descuento de confirmados) y la
-- caducidad (Gemini P2): sin ellos, cada sugerencia haría un scan secuencial.
create index if not exists idx_settlements_trip_status on settlements (trip_id, status);
create index if not exists idx_settlements_expires_at  on settlements (expires_at) where status = 'pending';
