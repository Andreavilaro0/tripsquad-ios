# ADR-0024 — Wedge "quién ya reservó": reservas por persona sobre el itinerario

- **Fecha:** 2026-07-25
- **Estado:** accepted
- **Dueña:** Andrea
- **Depende de:** ADR-0010 (modelo de dominio DDD), ADR-0018 (onboarding viajes + miembros:
  `owner`/`member`, expulsión), el módulo `Itinerario` (creador de actividad, `viajeCerrado`).
- **Spec:** `docs/superpowers/specs/2026-07-25-wedge-reserva-por-persona-design.md`.

## Contexto

La investigación de competidores (`docs/research/hallazgos.md`, momento mágico #3) identificó
la ansiedad #1 de un viaje de grupo: "¿habéis reservado todos?", resuelta hoy a base de mensajes
sueltos en WhatsApp. Ningún competidor evaluado (Wanderlog, Splitwise, Mindtrip) cubre un tablero
de "quién ya reservó qué". Es el foso puro de TripSquad y el primero de los dos wedges a construir
(el segundo, recibo→split/OCR, tiene spec propio).

Se necesitaba decidir dónde vive el estado de reserva, cuántos estados/modos soporta, y cómo se
autoriza sin abrir una fuga de información sobre qué existe en el viaje.

## Decisión

**El estado de reserva se engancha a una actividad existente del itinerario
(`ActividadItinerario`)**, no a una lista aparte. Una actividad tiene 0 o 1 reserva. Esto reusa
el itinerario ya construido y da de regalo el quick-win de "reservas tipadas" (patrón visto en
Wanderlog) sin crear un agregado nuevo.

### Modelo

- `Reserva` (tipo puro, `TripSquadExpenses/Reserva.swift`), atada por `activityId` (FK) +
  `tripId`.
- `kind: KindReserva` — enum cerrado: `.vuelo | .hotel | .coche | .tren | .seguro | .otro`.
- `mode: ModoReserva` — 2 modos:
  - `.cadaUnoElSuyo` — mapa `[MiembroId: EstadoReserva]`, solo de un **subconjunto** de miembros
    elegido al crear la reserva (por defecto todos los miembros del viaje en ese momento).
  - `.unoParaTodos` — `responsable: MiembroId?` + un único `estado`.
- `EstadoReserva` — 2 estados: `.pendiente | .reservado` (binario, sin `confirmado` ni otros).

**Por qué 2 estados:** basta para responder "¿habéis reservado todos?" de un vistazo. Añadir un
tercer estado (p. ej. `confirmado`) o vincularlo a pagos es una decisión posterior, con su propio
ADR si aparece la necesidad real — no se especula ahora.

**Por qué el subconjunto en `.cadaUnoElSuyo`:** resuelve el caso "no aplica" (quien ya vive en
Lisboa no necesita marcar el vuelo MAD→LIS del resto) de forma estructural, sin inventar un
tercer estado tipo "n/a". Un miembro que se une al viaje después **no** se auto-añade a
reservables ya creados; añadirlo es una edición explícita.

### Autorización

Dos gates distintos porque autorizan sobre cosas distintas:

- **Definir / quitar** el aspecto reserva de una actividad (`PUT`/`DELETE .../reservation`):
  **el creador de esa actividad, o el owner del viaje** — el mismo gate que editar/borrar la
  actividad en `CasosDeUsoItinerario`.
- **Marcar** el estado (`PUT .../reservation/status`): autoriza sobre la RESERVA, no la
  actividad.
  - `.cadaUnoElSuyo`: cada miembro marca su propio estado, o el owner marca el de cualquiera.
  - `.unoParaTodos`: solo el responsable marca el estado único, o el owner.

### Errores sin fuga de existencia

`ErrorReserva.noAutorizado` → **403**, y es DELIBERADAMENTE el mismo código tanto si el actor no
es miembro del viaje, como si el `tripId`/`activityId` no existe, como si es miembro pero no
puede tocar ese estado concreto. Mismo criterio que el resto del backend (ADR-0018, "no filtrar
existencia de viajes/códigos a no-autorizados"; el módulo settle sigue el mismo patrón).
Adicionalmente: `.viajeCerrado` → 409, `.reglaViolada(code)` → 422 (p. ej. marcar a un miembro no
incluido en el subconjunto, o `unoParaTodos` sin responsable al intentar marcar), y un raw value
de enum no reconocido en el body (`kind`/`mode`/`estado`) → 422 `enum_invalido` sin crashear
nunca — mismo criterio defensivo que el resto de rutas.

### Viaje cerrado

`viajeCerrado` bloquea **definir y marcar** (mismo criterio que itinerario), pero **no bloquea
quitar** — poder retirar el aspecto reserva de una actividad no cambia el estado del viaje ni
compromete nada, y evitar bloquearlo evita dejar datos huérfanos sin forma de limpiarlos una vez
el viaje está cerrado.

### Limpieza transaccional al expulsar / salir

Dentro de la **misma transacción** que `quitarMiembro`: se borran las filas de estado
por-persona del miembro saliente en `.cadaUnoElSuyo`; si era `responsable` de un
`.unoParaTodos`, se limpia a `responsable = null` + `estado = pendiente` (queda visible que hay
que reasignar, en vez de dejar un responsable fantasma). Consistente con la postura de seguridad
"expulsar revoca huella" ya aplicada a invitaciones (fix de seguridad #40, PR `fix/seguridad`).

### Endpoints

Todos bajo un viaje; auth base = miembro del viaje.

| Método | Ruta | Qué hace |
|---|---|---|
| `PUT` | `/trips/:tripId/itinerary/:itemId/reservation` | Define o edita el aspecto reserva de una actividad (`kind`, `mode`, subconjunto/responsable) |
| `DELETE` | `/trips/:tripId/itinerary/:itemId/reservation` | Quita el aspecto reserva (la actividad sigue viva) |
| `PUT` | `/trips/:tripId/itinerary/:itemId/reservation/status` | Marca el estado (propio, o de cualquiera si eres owner / responsable) |
| `GET` | `/trips/:tripId/reservations` | El tablero: todos los reservables del viaje con sus estados |

Todos los `PUT` son idempotentes (marcar el mismo estado dos veces es un no-op 200).

### Persistencia

`itinerary_reservations` (`activity_id` PK, FK a la actividad `ON DELETE CASCADE`, `trip_id`,
`kind`, `mode`, `responsible_id` nullable, `single_estado` nullable) +
`itinerary_reservation_members` (`activity_id` FK `ON DELETE CASCADE`, `member_id`, `estado`, PK
compuesta) para el subconjunto de `.cadaUnoElSuyo`. El `ON DELETE CASCADE` sobre la actividad
evita tener que orquestar el borrado del aspecto reserva a mano cuando se borra una actividad de
itinerario.

## Alternativas consideradas

- **Lista de reservas aparte del itinerario** (agregado nuevo, `Reserva` con su propio
  título/fecha) — descartada: duplica lo que ya modela `ActividadItinerario`, obliga a
  sincronizar dos fuentes de verdad (fecha de la actividad vs. fecha de la reserva) y pierde el
  quick-win de "reservas tipadas sobre lo que ya existe".
- **Un solo modo (siempre `cadaUnoElSuyo`)** — descartada: no cubre el caso real "Ana reserva el
  hotel para las 4" sin forzar a cada miembro a marcar algo que no gestiona; `unoParaTodos` con
  responsable es más honesto con cómo se reservan las cosas en la práctica.
- **3 estados desde el inicio (`pendiente/reservado/confirmado`)** — descartada: no hay señal de
  necesidad real todavía y añade densidad a una feature cuyo valor es precisamente la simpleza
  de un vistazo; se deja para un ADR posterior si aparece el caso de uso.
- **Auto-añadir miembros nuevos a reservables existentes** — descartada: el subconjunto se fija
  deliberadamente al crear (ver "por qué el subconjunto" arriba); auto-añadir rompería esa
  semántica sin avisar y podría marcar como "pendiente" algo que no le corresponde a un
  recién llegado.
- **`noAutorizado` diferenciado por causa (403 vs. 404)** — descartada: filtrar si un
  `tripId`/`activityId` existe a un actor no autorizado es una fuga de información; se unifica en
  403, igual que el resto del backend.

## Consecuencias

- El itinerario gana un aspecto opcional (reserva) sin convertirse en un agregado más pesado;
  cualquier cambio futuro al modelo de actividad debe tener en cuenta que puede cargar una
  reserva enganchada.
- El borrado de una actividad de itinerario borra en cascada su reserva — no hace falta lógica
  de aplicación para mantenerlo consistente, pero sí hay que recordarlo al tocar la migración de
  itinerario en el futuro.
- La limpieza al expulsar vive ahora en la misma transacción que `quitarMiembro`; cualquier
  módulo nuevo que guarde estado por-miembro (siguiendo este patrón) debería sumarse ahí en vez
  de crear un mecanismo de limpieza aparte.
- Queda pendiente y fuera de alcance de v1: notificaciones/nudges, tercer estado o vínculo con
  pagos, auto-detección de "reservado" desde email/adjunto, y el front del tablero (diseño
  aparte).
