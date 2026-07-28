# Diseño — Wedge "Quién ya reservó" (estado de reserva por persona)

> **Estado:** APROBADO en diseño (Andrea, 2026-07-25). Pendiente de convertir en plan de implementación (writing-plans).
> **Origen:** `docs/research/hallazgos.md` — momento mágico #3 (el wedge, foso puro). Primera de las 2 piezas del FOSO a construir; la segunda (recibo→split/OCR) tendrá su propio spec.
> **Alcance:** SOLO back (Swift). El front se diseña aparte.

## Goal

Dar al viaje un **tablero vivo de "quién ya reservó"**: convertir la ansiedad #1 del viaje de grupo ("¿habéis reservado todos?", 20 mensajes en WhatsApp) en un vistazo. Es el instinto #1 de Andrea y **ningún competidor lo tiene** (confirmado en la investigación: Wanderlog, Splitwise, Mindtrip no lo cubren) → foso puro.

## Decisión base (aprobada en brainstorming)

El estado de reserva **se engancha a una actividad del itinerario existente** (`ActividadItinerario`), no a una lista aparte. Reusa el itinerario y trae de regalo el quick-win de "reservas tipadas" que se vio en Wanderlog. Una actividad tiene **0 o 1** reserva.

## Modelo de datos

Tipo de dominio `Reserva`, atado a una actividad por `activityId`:

- `activityId: String` (FK → `ActividadItinerario`), `tripId: String`
- `kind: KindReserva` — `.vuelo | .hotel | .coche | .tren | .seguro | .otro` (enum cerrado)
- `mode: ModoReserva` — `.cadaUnoElSuyo | .unoParaTodos`
- Según el modo:
  - `.cadaUnoElSuyo`: mapa `[MiembroId: EstadoReserva]` **solo de los miembros incluidos** (subconjunto elegido al crear, por defecto todos los miembros del viaje).
  - `.unoParaTodos`: `responsable: MiembroId?` + `estado: EstadoReserva`
- `EstadoReserva: .pendiente | .reservado` (binario)

**Por qué solo 2 estados:** resuelve la pregunta "¿habéis reservado todos?" sin densidad. Ampliar (ej. `confirmado`) sería un ADR posterior si aparece la necesidad real.

**Por qué el subconjunto en `.cadaUnoElSuyo`:** resuelve el "no aplica" (quien vive en Lisboa no entra en el "vuelo") de forma estructural, sin un tercer estado.

### Persistencia (Postgres)

- `itinerary_reservations`: `activity_id` (PK, FK → actividad, ON DELETE CASCADE), `trip_id`, `kind`, `mode`, `responsible_id` (nullable, solo unoParaTodos), `single_estado` (nullable, solo unoParaTodos).
- `itinerary_reservation_members`: `activity_id` (FK, ON DELETE CASCADE), `member_id`, `estado`. PK compuesta `(activity_id, member_id)`. Solo se usa en `.cadaUnoElSuyo`.

## Dónde vive (sigue el molde de `Itinerario`/`Votacion`)

- **`Reserva.swift`** (TripSquadExpenses) — tipos puros (`Reserva`, `KindReserva`, `ModoReserva`, `EstadoReserva`, `ErrorReserva`). Sin lógica de auth.
- **`CasosDeUsoReserva.swift`** (TripSquadExpenses) — autorización + reglas de negocio. Aquí vive "quién puede marcar qué".
- **`RepositorioReservaPostgres.swift`** (TripSquadExpensesPostgres) — persistencia + query del tablero. Puerto en `Puertos.swift`, doble en `RepositorioEnMemoria` para tests.
- **`ReservaRoutes.swift`** (TripSquadServiceCore) — HTTP.
- **ADR nuevo** (`docs/decisions/`) — registra: modelo sobre itinerario, 2 estados, 2 modos, subconjunto por-persona, matriz de auth, errores sin fuga de existencia.

## Endpoints

Todo bajo un viaje. Auth base = miembro del viaje.

| Método | Ruta | Qué hace | Auth |
|---|---|---|---|
| `PUT` | `/trips/:tripId/itinerary/:activityId/reservation` | Marca una actividad como reservable o edita (`kind`, `mode`, participantes/responsable) | **creador de la actividad u owner** (igual que editar la actividad) |
| `DELETE` | `/trips/:tripId/itinerary/:activityId/reservation` | Quita el aspecto reserva (la actividad sigue viva) | creador u owner |
| `PUT` | `/trips/:tripId/itinerary/:activityId/reservation/status` | Marca estado. Body `{ memberId, estado }` (cadaUnoElSuyo) o `{ estado }` (unoParaTodos) | **cada uno su propio memberId, o el owner cualquiera**; en unoParaTodos el responsable o el owner |
| `GET` | `/trips/:tripId/reservations` | **El TABLERO**: todos los reservables del viaje con estados (vista "de un vistazo") | miembro |

Además: el **GET del itinerario** incluye un resumen compacto de reserva por actividad (para badge en la vista de día).

Todos los PUT son **idempotentes**.

### Flujo de ejemplo

1. Existe la actividad "Vuelo MAD→LIS".
2. `PUT .../reservation` con `kind=vuelo`, `mode=cadaUnoElSuyo`, `participantes=[los 4]`.
3. Cada miembro: `PUT .../reservation/status { yo, reservado }`.
4. Front pinta con `GET /reservations`: "✅ Iván · ⏳ Sara · ✅ Hotel (resp. Ana)".

## Casos límite y reglas

- **Viaje cerrado** → reservas de solo lectura (no crear/editar/marcar). Mismo criterio que itinerario (`viajeCerrado`).
- **Miembro expulsado o que sale** → en la **misma transacción** que `quitarMiembro`: se borran sus filas de estado por-persona; si era `responsable` de un `unoParaTodos`, se limpia a `responsable=null` + `pendiente` (visible que hay que reasignar). Consistente con la postura de seguridad "expulsar revoca huella" (cf. iy6).
- **Miembro nuevo** → NO se auto-añade a reservables existentes (el subconjunto se fijó al crear). Añadirlo es una edición explícita del reservable.
- **Errores sin fuga de existencia** (ADR-0018/0019) → `noAutorizado` cubre por igual "no eres miembro" / "no existe la actividad o la reserva" / "eres miembro pero no puedes tocar ese estado". Además `viajeCerrado` y `reglaViolada` (ej: marcar a un miembro no incluido, o `unoParaTodos` sin responsable al marcar).
- **Idempotencia** → marcar el mismo estado = no-op 200. Se usa PUT (idempotente), así que el bead 379 (idempotencia en POSTs) no aplica.
- **Validación** → `kind`/`mode`/`estado` son enums cerrados (422 si viene basura); los participantes deben ser subconjunto de los miembros actuales del viaje.

## Tests (estructura actual: dominio / expenses / servicio / integración)

- **Casos de uso** (`CasosDeUsoReserva`): matriz de auth — creador/owner crean; cada uno marca el suyo; owner marca cualquiera; miembro-no-incluido → `reglaViolada`; no-miembro → `noAutorizado`; viaje cerrado → `viajeCerrado`; `unoParaTodos` sin responsable al marcar → `reglaViolada`.
- **Cambios de membresía**: expulsar borra estados por-persona del expulsado y limpia el responsable si era suyo (test de la transacción `quitarMiembro`).
- **Repo Postgres**: round-trip, borrado en cascada con la actividad, y la query del tablero (`GET /reservations`).
- **Rutas/servicio**: códigos de estado — `noAutorizado` → **403** (consistente con los otros 7 módulos, NO 422 como el bug de Gastos, bead 55x); `viajeCerrado`/`reglaViolada` → 409/422 según el criterio de itinerario; enums basura → 422. PUT idempotente.
- **Integración**: flujo completo crear actividad → marcar reservable → miembros marcan → `GET /reservations` refleja el tablero.

## Fuera de alcance (v1)

- Notificaciones / nudges ("recuérdale a Sara que reserve") — front o iteración posterior.
- Tercer estado `confirmado` / pagos — ADR posterior si hace falta.
- Auto-detección de "reservado" desde un email/adjunto (eso lo cubriría el parseo de vuelos tipo TripIt, otra pieza).
- El front del tablero (pantalla) — su propio diseño.

## Dependencias

- Ninguna de back nuevo externa. Reusa: `ActividadItinerario`, `MiembroId`, la infra de auth de `Contexto.swift`/`Auth.swift`, y el patrón de `quitarMiembro` (para el borrado transaccional).
- **No** depende de FotoStorage/Brújula/OCR ni de APIs de pago.

## Beads

- Cerrar/crear el bead del wedge (era "bead a crear" en hallazgos.md) apuntando a este spec.
