# ADR-0009 — Estructura del servicio: monolito modular Swift con Clean Architecture

- **Fecha:** 2026-07-12
- **Estado:** accepted
- **Firmado:** 2026-07-14 por Andrea ("firma los ADRs y mergea todo")
- **Dueña:** Andrea
- **Origen:** bead R1 (`TripSquad-iOS-lea`), design doc Backend F3 (APPROVED 2026-07-11)

## Contexto

El backend de TripSquad necesita una estructura antes de escribir código (premisa
"investigación → ADR → contrato → código"). Restricciones: equipo de 1 persona +
fábrica de agentes, presupuesto 0€, Supabase como BaaS, el servicio Swift como
único escritor del dominio, y dominio delicado (dinero, membresía/privacidad,
edición concurrente). Fuentes ancla investigadas: Azure Architecture Center y
Well-Architected Framework (pilares Reliability y Security) — ver Fuentes.

## Decisión

1. **Monolito modular en Swift.** Un solo proceso desplegable. Los módulos son
   fronteras in-process con contratos explícitos (acoplamiento de compilación,
   no de red): `Expenses`, `Membership`, `Itinerary`, `Voting`, `Chat`, `Media`.
   El mapa definitivo de módulos lo fija R2 (DDD/bounded contexts); esta lista
   es la hipótesis de partida.
2. **Clean Architecture como organización interna** — la recomendación explícita
   de Microsoft para "non-trivial monolithic applications": un núcleo de dominio
   (entidades, invariantes, servicios de dominio, interfaces) sin dependencias
   hacia fuera; Infra/Data implementan las interfaces del núcleo; las
   dependencias apuntan siempre hacia dentro. Coherente con la constitution
   (Presentation/Domain/Data/Infra).
3. **El monolito ES el BFF — compartido para móvil.** Un solo backend sirve a
   los clientes móviles (iOS hoy, Android/Kotlin después — ADR-0008): el propio
   servicio agrega las lecturas del bento en una request, con formas de lectura
   pensadas para las pantallas de la app pero **agnósticas de plataforma**
   (nada Apple-specific en el contrato, premisa de ADR-0008). No se añade API
   gateway ni capa de agregación separada, ni un BFF por plataforma: se
   reevaluará solo si las necesidades de iOS y Android divergen de verdad.
4. **Cuatro patrones obligatorios desde el día 1** (catálogo Azure):
   - **Retry + Circuit Breaker, juntos** — toda llamada a Supabase es red; el
     catálogo indica emparejarlos (reintentar lo transitorio, cortar lo persistente).
   - **Anti-Corruption Layer** en Data/Infra — el Domain no conoce la forma de
     Supabase/PostgREST/PowerSync; cambiar de BaaS no toca el dominio.
   - **Transactional Outbox + idempotencia** — evento y entidad en la misma
     transacción Postgres; escrituras con Idempotency-Key + unique constraints
     (dedupe estructural, premisa D5.1 del design doc).
   - **RLS como defense-in-depth** — Postgres autoriza AUNQUE el servicio ya
     haya autorizado (Zero Trust "assume breach"): capa 2 contra fugas entre grupos.
5. **Complementos del pilar Reliability:** `/health` que verifica servicio +
   dependencia Supabase (Health Endpoint Monitoring), logs estructurados con
   correlation-id, rate limiting/throttling (supervivencia en free tier),
   degradación graceful a solo-lectura vía PowerSync si Supabase cae, backup
   `pg_dump` nocturno desde el Pi **restaurado al menos una vez** (el free tier
   no da PITR), y Valet Key (URLs firmadas cortas) para fotos.
6. **Identidades segregadas (pilar Security, SE:04/SE:05):** usuario (JWT+RLS,
   anon key SOLO lectura) ≠ servicio (rol Postgres dedicado con grants mínimos,
   jamás `service_role` en clientes) ≠ CI ≠ admin. Secretos con plan de rotación.

## Alternativas consideradas

- **Microservicios** — la propia doc de Microsoft los descalifica para este
  equipo: "requires a mature DevOps culture… carefully evaluate whether the
  team has the skills". Con 1 persona añaden service discovery, consistencia
  distribuida y versionado de red sin ningún beneficio. Revisar solo cuando
  haya >1 equipo escribiendo código.
- **Web-Queue-Worker** — para dominios simples con tareas intensivas; el
  dominio de TripSquad es rico (saldos, membresía, concurrencia) y su parte
  asíncrona cabe en background jobs + outbox dentro del monolito.
- **Supabase-only (sin servicio propio)** — ya descartada en el design doc F3:
  rompe el único-escritor y el dedupe estructural.
- **Saga / compensaciones distribuidas** — innecesario: no hay transacciones
  entre servicios; una transacción Postgres + Compensating Transaction puntual
  (deshacer liquidación) bastan.

## Trade-off registrado conscientemente

WAF RE:07 recomienda literalmente "avoid building monolithic applications…
use loosely coupled services" — está escrito para enterprise multi-equipo y
contradice a RE:01 (simplicidad como propiedad de fiabilidad: "it's often what
you remove rather than what you add that leads to the most reliable solutions")
y a la guía .NET de arquitecturas comunes. Esta decisión se apoya en RE:01 +
esa guía, asumiendo el trade-off: si el equipo crece o un módulo necesita
escalar aparte, el camino de salida es extraer módulos ya delimitados (por eso
las fronteras internas son obligatorias, no cosméticas).

## Consecuencias

- `/plan-eng-review` decide Hummingbird 2 vs Vapor DENTRO de esta estructura
  (la elección de framework no altera capas ni patrones).
- R2 (DDD) hereda la lista de módulos como hipótesis a validar; R3–R6 diseñan
  dentro de estas fronteras (motor de saldos = servicio de dominio puro,
  testeable sin DB).
- El slice vertical de gastos (Fase S) debe estrenar los 4 patrones del día 1;
  la suite de contrato verifica idempotencia y paridad RLS↔sync-rules.
- Flujos clasificados por criticidad antes de codificar (RE:02): crear/liquidar
  gasto y unirse a grupo = críticos; chat y fotos = degradables.
- Coste aceptado: disciplina de fronteras internas sin red que las imponga —
  la vigilan los revisores (checklist §1/§3) y, cuando exista código, un test
  de dependencias entre módulos.

## Fuentes

- Estilos de arquitectura y tabla de dominios: https://learn.microsoft.com/en-us/azure/architecture/guide/architecture-styles/
- Requisitos de madurez de microservicios: https://learn.microsoft.com/en-us/azure/architecture/guide/architecture-styles/microservices
- Clean Architecture para monolitos (guía .NET): https://learn.microsoft.com/en-us/dotnet/architecture/modern-web-apps-azure/common-web-application-architectures
- Catálogo de patrones (Retry, Circuit Breaker, ACL, Outbox, Throttling, Valet Key, BFF): https://learn.microsoft.com/en-us/azure/architecture/patterns/ · https://learn.microsoft.com/en-us/azure/architecture/databases/guide/transactional-out-box-cosmos
- WAF Reliability (RE:01–RE:10): https://learn.microsoft.com/en-us/azure/well-architected/reliability/checklist · https://learn.microsoft.com/en-us/azure/well-architected/reliability/principles · https://learn.microsoft.com/en-us/azure/well-architected/reliability/self-preservation
- WAF Security (SE:01–SE:12): https://learn.microsoft.com/en-us/azure/well-architected/security/checklist · https://learn.microsoft.com/en-us/azure/well-architected/security/principles
