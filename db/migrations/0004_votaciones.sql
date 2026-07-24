-- Migración 0004 — votaciones (M4, ADR-0019 borrador —
-- docs/design/votaciones-scope-y-plan.md). `poll_votes` ya existía desde 0001
-- (dedupe estructural por PK(poll_id, member_id), ADR-0012 §2) pero sin la
-- tabla `polls` a la que referenciar. Append-only: solo añade, no reescribe.

create table polls (
    id          text primary key,
    trip_id     text not null references trips(id),
    question    text not null,
    options     jsonb not null
                check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) >= 2),  -- defensa en BD (Codex P2)
    created_by  text not null,
    created_at  timestamptz not null default now(),
    closed_at   timestamptz
);

create index if not exists idx_polls_trip on polls (trip_id);
create index if not exists idx_poll_votes_poll on poll_votes (poll_id);

-- FK de poll_votes.poll_id -> polls.id (antes poll_votes existía sin la tabla polls):
alter table poll_votes add constraint fk_poll_votes_poll
    foreign key (poll_id) references polls(id) on delete cascade;
