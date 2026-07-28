# M2 — Onboarding: viajes + miembros — Scope / diseño (PROPUESTA)

> **Estado:** PROPUESTA para decisión de Andrea. NADA se codifica hasta que apruebes la
> dirección + resuelvas las **preguntas abiertas** (constitution §2, design-first). Este doc
> es el paso de diseño que el roadmap (M2) marca como necesario antes del plan.
> Autor: Claude (sesión autónoma 2026-07-23). NO es un ADR aceptado; el ADR se escribe cuando
> decidas.

## Por qué esto es lo primero del backend "de verdad"
Hoy hay tablas `trips` y `trip_members`, pero **ninguna API** para crear un viaje ni sumar
al squad — los miembros se siembran a mano en tests. Sin onboarding, **nada del bento**
(gastos, settle, votaciones, itinerario, chat, fotos) tiene dónde colgarse en la vida real.
Es la dependencia de M3..M8.

## Qué ya existe (verificado)
- `trips (id text pk, closed_at timestamptz?)` — mínima.
- `trip_members (trip_id, member_id, left_at?)` — con `left_at` para expulsión/salida (ya lo
  usa `esMiembro`: `WHERE left_at IS NULL`).
- Auth: JWT de Supabase; `sub` = `member_id` (ADR-0014). **Estar autenticado ≠ estar en un
  viaje**: la cuenta la da Supabase; la pertenencia al viaje la gestiona la app (trip_members).

## Modelo mental propuesto
- **Crear un viaje** → el creador entra como primer miembro.
- **Invitar** → el squad entra por un **código/enlace de invitación** (no hace falta email ni
  directorio de usuarios; encaja con auth de Supabase y es lo natural en apps de grupo).
- **Salir / expulsar** → marca `left_at` (no borra: preserva historial de gastos/settle).
- **Cerrar** viaje → `closed_at`, pasa a solo-lectura.

## Contrato HTTP propuesto (todo bajo JWT; `actor = ctx.actor`)
| Método · Ruta | Quién | Efecto |
|---|---|---|
| `POST /trips` | cualquier autenticado | crea viaje; el actor entra como miembro (¿owner?) |
| `GET /trips` | autenticado | lista los viajes del actor |
| `GET /trips/:id` | miembro | detalle + lista de miembros |
| `POST /trips/:id/invites` | miembro (¿u owner?) | genera un código de invitación (con caducidad) |
| `POST /trips/join` | autenticado | canjea `{code}` → entra como miembro |
| `DELETE /trips/:id/members/:memberId` | owner (expulsar) o uno mismo (salir) | marca `left_at` |
| `POST /trips/:id/close` | owner | `closed_at` (solo-lectura) |

## Esquema nuevo (migración 0003, append-only)
- `trips`: añadir `name text not null`, `created_by text not null`, `created_at timestamptz default now()`, ¿`base_currency text default 'EUR'`?
- `trip_members`: añadir `role text not null default 'member'` (si hay roles), `joined_at timestamptz default now()`.
- Nueva `trip_invites (code text pk, trip_id text, created_by text, expires_at timestamptz, revoked_at timestamptz?, max_usos int?, usos int default 0)`.

## Clean Architecture (encaje)
Mismo patrón que gastos/settle: dominio `Viaje`/`Miembro` + puerto `ViajeRepositorio` +
casos de uso (`crearViaje`, `invitar`, `unirse`, `salir`, `expulsar`, `cerrar`) + adaptadores
en-memoria/Postgres + rutas Hummingbird. La membresía ya la consume `Membresia` (settle/gastos
la reutilizan).

## ⚠️ PREGUNTAS ABIERTAS (necesitan tu decisión)

1. **Mecanismo de invitación** — recomiendo **(a) código/enlace** (simple, sin email, mobile).
   Alternativas: (b) por email/username (necesita directorio + cuenta previa), (c) QR/deep-link.
   ¿Cuál?
2. **Roles** — ¿**plano** (todos iguales, cualquiera invita/expulsa) o **owner** (el creador
   tiene poderes: expulsar, cerrar, revocar invitaciones)? El espíritu "squad" sugiere plano,
   pero owner da responsabilidad clara. Recomiendo **owner ligero** (creador puede cerrar/expulsar;
   cualquiera invita).
3. **Unirse: ¿instantáneo o con aprobación?** Canjear el código, ¿entra directo, o el owner
   aprueba? Recomiendo **instantáneo** (el código ES la autorización) para MVP.
4. **Caducidad/uso de invitaciones** — ¿el código caduca (p.ej. 7 días)? ¿un solo uso o varios
   (un enlace para todo el grupo)? Recomiendo **enlace multi-uso con caducidad 7d + revocable**.
5. **Salir con deudas** — ¿se puede salir de un viaje si debes/te deben dinero (settle sin
   saldar)? ¿Se bloquea, se avisa, o da igual? (Toca la integración con settle.)
6. **Campos del viaje (MVP)** — ¿solo `name`? ¿fechas, moneda base, foto de portada? Recomiendo
   MVP = `name` (+ `base_currency` que ya asume 'EUR' el motor de dinero).
7. **Cerrar vs borrar** — ¿existe "borrar viaje" o solo "cerrar" (solo-lectura)? Borrar cruza
   con RGPD (o1v). Recomiendo **solo cerrar** por ahora.
8. **Límite de tamaño del squad** — ¿tope de miembros por viaje? (afecta a settle/notif). Recomiendo
   un tope generoso configurable (p.ej. 50) para evitar abusos, no como feature.

## MVP recomendado (para timeboxear)
Si quieres lo mínimo jugable: `POST /trips`, `GET /trips`, `GET /trips/:id`,
`POST /trips/:id/invites`, `POST /trips/join`, `DELETE .../members/:id` (salir + expulsar).
`close` y roles finos pueden ir en una segunda ola. Con eso, un squad ya puede formarse y
usar gastos/settle.

## Siguiente paso (cuando apruebes)
1. Escribo el **ADR-0018** (transcribe tus decisiones de las 8 preguntas).
2. Plan detallado (writing-plans) → construcción por subagentes + gates + revisión de otro
   modelo + tu firma.
3. Desbloquea M3 (endurecer gastos con miembros reales) y todo lo demás.
