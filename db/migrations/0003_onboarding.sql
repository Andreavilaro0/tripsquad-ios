-- Migración 0003 — onboarding: viajes con nombre/owner, roles de miembro,
-- invitaciones por código (ADR-0018). Append-only sobre 0001: solo añade
-- columnas/tablas, no reescribe nada existente.
--
-- NOTA: `trips`/`trip_members` están vacías (no prod), así que los `default ''`
-- no afectan filas reales.

alter table trips
    add column name text not null default '',
    add column base_currency text not null default 'EUR',
    add column created_by text not null default '',
    add column created_at timestamptz not null default now();

alter table trip_members
    add column role text not null default 'member' check (role in ('owner', 'member')),
    add column joined_at timestamptz not null default now();

-- Invitaciones por código (ADR-0018 §1/§4): multi-uso, caducan a 7 días,
-- revocables por el owner. `code` es la PK: debe generarse aleatorio y
-- url-safe (≥128 bits) en la capa de aplicación — nunca secuencial ni derivado.
create table trip_invites (
    code        text primary key,
    trip_id     text not null references trips(id),
    created_by  text not null,
    expires_at  timestamptz not null,
    revoked_at  timestamptz,
    created_at  timestamptz not null default now()
);

-- Acelera "¿de qué viajes soy miembro activo?" (rol(actor) != nil en el
-- dominio) y las futuras RLS de Postgres sobre trip_members.
create index if not exists idx_trip_members_member on trip_members (member_id) where left_at is null;
