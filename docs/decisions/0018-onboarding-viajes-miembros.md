# ADR-0018 — Onboarding: viajes + miembros (invitación por código)

- **Fecha:** 2026-07-23
- **Estado:** **proposed (provisional autónoma — PENDIENTE de firma de Andrea)**
- **Dueña:** Andrea
- **Decide:** Claude en sesión autónoma con defaults conservadores (mandato "no pares hasta
  que el backend esté hecho"). Andrea puede **revocar/ajustar** cualquier punto al revisar el
  PR o con un ADR nuevo que lo supersede — las decisiones no son definitivas hasta su firma.
- **Depende de:** ADR-0014 (JWT; `sub` = member_id), ADR-0009/0010 (monolito modular, DDD).
- **Scope de diseño:** `docs/design/onboarding-scope.md` (con las 8 preguntas abiertas).

## Contexto
No hay API para crear un viaje ni sumar al squad; es la dependencia de todo el bento. Se
necesita una decisión para poder codificar. Ver scope.

## Decisión (defaults conservadores, revocables)
1. **Invitación por código/enlace.** El servidor genera un `code` opaco; canjearlo une al
   actor al viaje. Sin email ni directorio de usuarios (encaja con Supabase, mobile-first).
2. **Rol "owner ligero".** El creador es `owner`; puede cerrar el viaje, expulsar miembros y
   revocar invitaciones. **Cualquier miembro** puede invitar. El resto son `member`.
3. **Unirse es instantáneo** al canjear un código válido (el código ES la autorización; sin
   aprobación manual en el MVP).
4. **Invitaciones multi-uso, caducan a 7 días, revocables.** Un enlace sirve para todo el
   grupo hasta que caduca o el owner lo revoca.
5. **Salir con deudas: se permite pero se avisa.** La respuesta al salir incluye una señal si
   el miembro tiene saldo != 0 (no bloquea; settle es un flujo aparte). Provisional.
6. **Campos de viaje MVP:** `name` + `base_currency` (default `'EUR'`, que ya asume el motor
   de dinero). Fechas/foto de portada, después.
7. **Solo "cerrar" (closed_at), no "borrar".** Borrar cruza con RGPD (bead o1v); fuera de MVP.
8. **Tope de miembros por viaje: 50** (guardarraíl anti-abuso, no feature).

## Consecuencias
- Migración **0003**: `trips` (+name, created_by, created_at, base_currency); `trip_members`
  (+role, joined_at); nueva `trip_invites`.
- Dominio `Viaje` + puerto `ViajeRepositorio` + casos de uso + adaptadores + rutas.
- La `Membresia` existente (settle/gastos) se apoya en `trip_members` real por fin.
- Endpoints: `POST /trips`, `GET /trips`, `GET /trips/:id`, `POST /trips/:id/invites`,
  `POST /trips/join`, `DELETE /trips/:id/members/:memberId`, `POST /trips/:id/close`.

## Riesgos / seguridad (a verificar en la construcción)
- Autorización estricta: solo miembros ven/operan su viaje; solo owner cierra/expulsa/revoca.
- El `code` debe ser **imposible de adivinar** (aleatorio ≥128 bits, comparación en tiempo
  constante no crítica al ser aleatorio largo, pero sí índice único).
- No filtrar existencia de viajes/códigos a no-autorizados (403 uniforme, como en settle).
- Canjear un código caducado/revocado → rechazo claro, sin efecto.

## Firma
Provisional; **pendiente del visto bueno de Andrea**. Construido en autónomo para no bloquear
el resto del backend; totalmente reversible antes de merge a develop.
