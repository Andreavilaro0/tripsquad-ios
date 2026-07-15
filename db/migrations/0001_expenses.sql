-- Migración 0001 — esquema del slice vertical de gastos (Fase S).
-- Fuentes: ADR-0011 (dinero), ADR-0012 (idempotencia + dedupe), ADR-0013 (sync +
-- tombstones), ADR-0015 (bigint, :settle, write_conflicts, historial de ediciones).
--
-- REGLA DE ORO (ADR-0015 §4, gate G3): todo el DINERO es `bigint` de céntimos.
-- Jamás `numeric` ni `double precision` para importes que se suman. La única
-- excepción es `fx_rate`, que es una TASA (no se acumula), y ahí `numeric` es
-- correcto.

-- Viajes ------------------------------------------------------------------------
create table trips (
    id                  text primary key,          -- UUID de cliente
    currency_reference  text not null,             -- ISO 4217, fijada al crear el viaje
    closed_at           timestamptz,               -- viaje cerrado -> rechazo permanente
    created_at          timestamptz not null default now()
);

-- Membresía: la ÚNICA fuente de verdad de autorización (ADR-0013 §4). Tanto las
-- RLS como las sync rules de PowerSync saldrán de aquí.
create table trip_members (
    trip_id     text not null references trips(id),
    member_id   text not null,
    left_at     timestamptz,                       -- null = miembro activo; expulsado deja de ver
    joined_at   timestamptz not null default now(),
    primary key (trip_id, member_id)
);

-- Gastos ------------------------------------------------------------------------
create table expenses (
    id                  text primary key,          -- UUID de cliente => dedupe estructural (ADR-0012 §2)
    trip_id             text not null references trips(id),
    paid_by             text not null,
    -- DINERO en bigint de céntimos (gate G3). Congelado en la divisa de referencia.
    amount_reference    bigint not null,
    amount_original     bigint not null,
    currency_original   text not null,
    -- FX: columnas ya, aunque el MVP sea mono-divisa (ADR-0011 §5, migrar después es caro).
    fx_rate             numeric,                   -- TASA, no dinero -> numeric es correcto
    fx_rate_source      text,
    fx_rate_at          timestamptz,
    split_kind          text not null check (split_kind in ('equal','weight','exact')),
    split               jsonb not null,
    etag                text not null,             -- versión para If-Match (ADR-0013 §2)
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),
    deleted_at          timestamptz                -- tombstone estructural (ADR-0013 §5)
);
create index expenses_trip_idx on expenses (trip_id) where deleted_at is null;

-- Cuotas de reparto EXACTO en tabla tipada (hallazgo de Codex): para
-- `split_kind='exact'` las cuotas SON dinero, y guardarlas en el `split` jsonb las
-- dejaría fuera del gate G3 (podrían ser decimales, negativas o no sumar). Aquí van
-- con `amount_minor bigint` y check de no-negatividad. Para equal/weight, las cuotas
-- se DERIVAN (no se guardan), así que esta tabla solo se puebla en repartos exactos.
create table expense_shares (
    expense_id      text not null references expenses(id),
    member_id       text not null,
    amount_minor    bigint not null check (amount_minor >= 0),
    primary key (expense_id, member_id)
);

-- Liquidaciones: dedupe estructural con transfer_index (ADR-0015 §5). `round` es
-- ordinal de presentación, JAMÁS clave de dedupe.
create table settlements (
    id              text primary key,              -- uuidv5(settlementId, from||to||transferIndex)
    trip_id         text not null references trips(id),
    settlement_id   text not null,
    from_member     text not null,
    to_member       text not null,
    transfer_index  int  not null,
    amount_minor    bigint not null,               -- DINERO en bigint
    round           int  not null,
    created_at      timestamptz not null default now(),
    unique (trip_id, settlement_id, from_member, to_member, transfer_index)
);

-- Votos: dedupe estructural (ADR-0012 §2).
create table poll_votes (
    poll_id     text not null,
    member_id   text not null,
    choice      text not null,
    created_at  timestamptz not null default now(),
    primary key (poll_id, member_id)
);

-- Idempotencia (diseño de Brandur, ADR-0012 §2). Capa 1: higiene + replay.
create table idempotency_keys (
    user_id         text not null,
    idempotency_key text not null,
    request_hash    text not null,                 -- sha256 del cuerpo canónico (detecta 422)
    first_sent      timestamptz not null,          -- lo firma el CLIENTE en generación local (ADR-0015 §4)
    locked_at       timestamptz,                   -- petición en vuelo (timeout ~30s)
    recovery_point  text,                          -- reanudar tras crash a mitad
    response_code   int,
    response_body   jsonb,
    created_at      timestamptz not null default now(),
    primary key (user_id, idempotency_key)
);
-- Retención de 60 días (ADR-0012 §3): un reaper diario borra lo viejo.
create index idempotency_first_sent_idx on idempotency_keys (first_sent);

-- Dead-letter visibles que se sincronizan de vuelta al cliente. NUNCA se responde
-- 4xx a la cola: se responde 200 y se escribe aquí (ADR-0012 §4, ADR-0015 §2).
create table write_rejections (
    id          bigint generated always as identity primary key,
    user_id     text not null,
    trip_id     text,
    entity_id   text,
    reason      text not null,                     -- trip_closed | not_member | idempotency_key_expired | ...
    detail      jsonb,
    created_at  timestamptz not null default now()
);
create table write_conflicts (
    id          bigint generated always as identity primary key,
    user_id     text not null,
    trip_id     text not null,
    entity_id   text not null,
    server_etag text not null,
    server_value jsonb not null,
    your_value  jsonb not null,
    created_at  timestamptz not null default now()
);

-- Historial de ediciones append-only (ADR-0015 §15): todos editan, todo queda
-- registrado campo a campo.
-- ⚠️ PENDIENTE (bead o1v): el crypto-shredding del texto libre (old_value/new_value
-- de campos personales) para el derecho al olvido. Aquí van los campos
-- estructurales en claro; el diseño de claves de cifrado es su propio bead.
create table expense_revisions (
    id          bigint generated always as identity primary key,
    expense_id  text not null,
    edited_by   text not null,
    edited_at   timestamptz not null default now(),
    field       text not null,
    old_value   jsonb,
    new_value   jsonb
);
create index expense_revisions_expense_idx on expense_revisions (expense_id);

-- ⚠️ PENDIENTE (bead 5n3): las políticas RLS. El servicio usa un rol Postgres
-- dedicado, así que las RLS por usuario necesitan SET LOCAL role + request.jwt.claims
-- o funciones security definer. El mecanismo exacto se investiga antes de la primera
-- escritura real; no se inventa aquí.
