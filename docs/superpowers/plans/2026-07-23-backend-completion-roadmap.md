# Backend Completion — Roadmap

> **Qué es esto:** el mapa para *acabar el backend* de TripSquad. NO es un plan de tareas
> ejecutable (eso es un plan por subsistema); es el programa: qué falta, en qué orden, qué
> está diseñado vs necesita diseño, y qué beads cierra cada bloque. Cada subsistema se
> detalla en su propio plan `docs/superpowers/plans/…` justo antes de construirlo (Scope
> Check de writing-plans). Constitución: **nada se codifica sin diseño+spec aprobados**.

## Estado real hoy (verificado 2026-07-23)

**Existe (backend Swift/Hummingbird, desplegado en Render):**
- Rutas: `POST/PATCH/DELETE /trips/:id/expenses`, `GET /trips/:id/settlement/suggestion`,
  `POST /sync/upload`, `/health`, `/live`. **7 rutas — solo cubren gastos + sugerir.**
- Dominio: motor de saldos (ADR-0011), Dinero Int64. Idempotencia (ADR-0012). JWT real
  (ADR-0014). Cola sync (ADR-0013). Postgres (migración 0001). Clean Arch (ADR-0009/0010).
- Tablas: trips, trip_members, expenses, expense_shares, settlements, poll_votes,
  idempotency_keys, write_rejections, write_conflicts, expense_revisions.

**El bento son 6 piezas** (CLAUDE.md): chat · itinerario · gastos+liquidación · votaciones
· fotos · Brújula IA. Cobertura backend: **1 de 6** (gastos), y la liquidación a medias.

## Secuencia para acabar el backend

Orden por: (1) desbloquear "app usable de punta a punta" antes que features sueltas;
(2) terminar lo empezado; (3) barato-primero. **D** = diseñado, listo para plan+código.
**Ð** = necesita un paso de diseño (ADR/scope) antes del plan.

| # | Bloque | Estado | Cierra beads | Depende de |
|---|---|---|---|---|
| **M1** | **`:settle` flujo de confirmación** (5 rutas + estados + outbox + caducidad + balances↔confirmed) | **D** (ADR-0017 + scope) | 8hn, xsx, 649 | — |
| **M2** | **Onboarding: viajes + miembros** (crear viaje, invitar, unirse, roles, salir) | **Ð** necesita ADR+scope | (nuevo) | — |
| **M3** | **Endurecimiento gastos** (historial expense_revisions, RGPD crypto-shred, If-Match por campo, DELETE no filtra viaje ajeno, Idempotency-Key+clientId) | **Ð** parcial (beads describen) | p4b, o1v, 7yy, iou, 00i | M2 (miembros) |
| **M4** | **Votaciones** (poll + poll_votes: crear, votar, cerrar, resultados) | **Ð** tabla existe, sin diseño de endpoints | (nuevo) | M2 |
| **M5** | **Itinerario** (días, actividades, orden, quién propone) | **Ð** sin diseño | (nuevo) | M2 |
| **M6** | **Chat** (mensajes por viaje, tiempo real / sync, lecturas) | **Ð** sin diseño; decisión grande (¿realtime propio vs 3rd-party?) | (nuevo) | M2 |
| **M7** | **Fotos** (subida, almacenamiento, álbum del viaje) | **Ð** sin diseño; decisión de storage (S3/R2/Supabase) | (nuevo) | M2 |
| **M8** | **Brújula IA** (asistente; usa API de pago) | **Ð** sin diseño; gate de gasto en APIs (CLAUDE.md) | (nuevo) | M2..M5 (contexto del viaje) |
| **X** | **Cross-cutting / infra** (RLS real 5n3, dónde corre el servicio #2/ecz, golden vectors Kotlin 0i9, PropertyBased 487, watchdog pinger 6l2, rotar keys si7, pass Pi 535) | mixto | 5n3, 0i9, 487, 6l2, si7, 535 | transversal |

### Racional del orden
- **M1 primero**: está diseñado, medio construido, y cierra un P0 (8hn) + 2 P1. Acabar lo
  empezado antes de abrir frentes nuevos.
- **M2 segundo**: es la **puerta de entrada** — hoy no se puede crear un viaje ni invitar al
  squad por API (los miembros se siembran a mano en tests). Sin M2, M4–M8 no tienen dónde
  colgarse en la vida real. Necesita un ADR de diseño (mecanismo de invitación, roles,
  join/leave, relación con auth Supabase) antes de plan.
- **M3** aprovecha que ya existe el vertical de gastos; endurece lo que los beads señalan.
- **M4 votaciones** es la siguiente pieza más barata (media tabla hecha).
- **M5–M8** son piezas nuevas grandes, cada una con su decisión de diseño/infra (chat
  realtime, storage de fotos, gasto en IA). Se diseñan al llegar.
- **X** se intercala: RLS (5n3) y "dónde corre el servicio" (#2) conviene resolverlos
  pronto porque afectan a todo; el resto son mejoras de CI/seguridad no bloqueantes.

## Definición de "backend acabado" (MVP jugable)
El backend está *acabado para MVP* cuando un squad puede, **solo por API**: crear un viaje e
invitar/unirse (M2), meter gastos y liquidar con confirmación (M1+M3), votar (M4), armar
itinerario (M5) y chatear (M6). Fotos (M7) y Brújula (M8) pueden ir en una segunda ola si
hace falta timeboxear. RLS real (5n3) y hosting definitivo (#2) antes de abrir a usuarios.

## Cómo se ejecuta cada bloque
1. (Si es **Ð**) diseño → ADR + scope, aprobación de Andrea.
2. Plan detallado del subsistema (`writing-plans`), tareas TDD.
3. Construcción por subagentes (uno por tarea) + revisión de otro modelo + gates
   (xcodebuild/SwiftLint/gitleaks/semgrep) + PR + review bot Codex + firma de Andrea.

## Siguiente paso inmediato
**M1** está listo para plan detallado y código (ya diseñado en ADR-0017 + scope). Es el
único bloque **D** grande. Su plan es el primer plan por subsistema a escribir.
