# ADR-0028 — Endurecimiento de confirmaciones antes de encender DeepSeek (a62)

- **Fecha:** 2026-07-28
- **Estado:** accepted
- **Dueña:** Andrea
- **Depende de / enmienda:** ADR-0026 (confirmaciones dy5). Este ADR **resuelve la
  decisión DEFERIDA** que ADR-0026 §Consecuencias dejó abierta (clave de idempotencia
  en `unoParaTodos`) y añade dos endurecimientos de coste/consistencia. ADR-0026 sigue
  `accepted`; no se edita (append-only, README de decisiones).

## Contexto

El bead `a62` recoge tres hallazgos de la revisión final (opus) de dy5, a cerrar
**antes** de configurar `DEEPSEEK_API_KEY` en producción (encender el adaptador de pago
es un gate de alto riesgo, CLAUDE.md). El subsistema de confirmaciones ya estaba wireado
y GATED, pero con tres bordes:

1. **Coste de tokens sin techo.** El texto de confirmación (input) no tenía tope de
   longitud, y la petición al LLM no fijaba `max_tokens` (output). Un texto enorme o una
   respuesta desbocada infla el coste una vez la key esté activa.
2. **Guardado + marcado no atómicos.** `registrarConfirmacion` hacía dos llamadas de
   puerto sueltas —`guardarConfirmacion` y luego `marcarEstado`—, cada una con su propia
   transacción en Postgres. Si el proceso muere entre medias, queda confirmación guardada
   con estado `pendiente`: inconsistencia observable.
3. **Idempotencia por-actor en `unoParaTodos`.** La clave era `(activityId, actor)`. En un
   reservable `unoParaTodos`, responsable Y owner pueden subir confirmación; con dos claves
   distintas, son **dos llamadas de pago al LLM** para un único estado compartido.

## Decisión

**1. Cap de coste (input + output).**
- **Input:** `CasosDeUsoReserva.maxLongitudConfirmacion = 20_000` caracteres. Por encima,
  `registrarConfirmacion` devuelve `reglaViolada("confirmacion_muy_larga")` **antes** de
  redactar/llamar al LLM. El chequeo va **después** de la comprobación de idempotencia (un
  reenvío ya-registrado sigue siendo gratis). 20 000 chars ≈ una confirmación de viaje muy
  larga con holgura (un billete/reserva típico son unos pocos KB); acota el peor caso sin
  recortar entradas legítimas.
- **Output:** `max_tokens = 512` en el body de `POST /chat/completions`. El JSON esperado
  (`DatosJSON`: 4 campos) es diminuto; 512 es techo de sobra y evita pagar de más si el
  modelo se desmadra. `max_tokens` es campo estándar de la API compatible-OpenAI de DeepSeek
  (verificado Context7 al escribir el adaptador). Se conserva además el tope de 1 MiB sobre
  el cuerpo de respuesta HTTP (defensa de memoria, ADR-0026 §Anti-prompt-injection).

**2. Guardado + marcado atómicos (donde el adaptador lo permite).**
Nuevo método de puerto `ReservaRepositorio.guardarConfirmacionYMarcarReservado(...)` que
sustituye al par `guardarConfirmacion` + `marcarEstado` en `registrarConfirmacion`.
- **Adaptador Postgres:** ejecuta el UPSERT de la confirmación **y** el UPDATE del estado
  `.reservado` en **una sola `withTransaction`** — un fallo entre medias hace rollback de
  ambos; nunca queda "confirmación guardada + estado pendiente".
- **Adaptador en-memoria:** sin transacciones reales, las hace **secuencialmente**.
  Documentado como aceptable a propósito: `RepositorioEnMemoria` es un doble de test/dev
  que no persiste (no hay durabilidad que corromper), y al ser un `actor` ninguna otra
  tarea observa el estado intermedio (aislamiento de actor). La atomicidad que importa en
  producción la da Postgres.

**3. Idempotencia por-actividad en `unoParaTodos`** (resuelve el deferido de ADR-0026):
la clave canónica de la confirmación pasa a ser **por-actividad** en `unoParaTodos` —
`(activityId, responsable)`— sin importar quién suba (responsable u owner). En
`cadaUnoElSuyo` se mantiene **por-actor** —`(activityId, actor)`—, porque ahí cada
participante confirma la suya. Efecto: responsable y owner subiendo el mismo reservable
`unoParaTodos` = **una sola llamada al LLM**. El caso de uso deriva el `miembro` canónico
(el `responsable`, garantizado no-nil en ese path por el gate previo) y lo usa tanto para
la lectura de idempotencia como para el guardado/marcado.

## Alternativas consideradas

- **Idempotencia por-actor también en `unoParaTodos`** (statu quo de ADR-0026) — descartada:
  es el borde de doble-coste que a62 viene a cerrar. Se elige la recomendación por-defecto de
  ADR-0026 (una llamada por actividad).
- **Cap de input más bajo (p. ej. 4 000 chars)** — descartado: arriesga rechazar
  confirmaciones legítimas largas (itinerarios multi-tramo). 20 000 deja holgura y sigue
  acotando el peor caso.
- **Transacción a nivel de caso de uso (Unit of Work genérico)** — descartada para v1:
  sobre-ingeniería; el puerto ya expresa la operación compuesta con un único método, y el
  único punto que la necesita es este. Clean Architecture se mantiene (el dominio no conoce
  la transacción; la garantiza el adaptador).
- **Guardar la confirmación bajo el `actor` real en `unoParaTodos`** (no bajo el
  responsable) — descartada: rompería la idempotencia por-actividad (dos slots distintos).
  El responsable es la clave natural del estado compartido.

## Consecuencias

- El gasto en DeepSeek queda acotado por request (input ≤ 20 000 chars, output ≤ 512 tokens)
  y una confirmación reenviada nunca re-paga (idempotencia). En `unoParaTodos`, como mucho
  **una** llamada de pago por reservable, la suba quien la suba.
- `registrarConfirmacion` ya no puede dejar estado inconsistente en Postgres entre el
  guardado y el marcado.
- En `unoParaTodos`, la confirmación se persiste bajo el `member_id` del **responsable**
  (clave canónica), aunque la haya subido el owner. Cualquier lector de
  `itinerary_reservation_confirmations` debe asumir esta semántica para ese modo.
- **Gate para Andrea:** con estos tres hallazgos cerrados, el bloqueo técnico de `a62`
  desaparece. Encender `DEEPSEEK_API_KEY` en producción sigue requiriendo su OK explícito
  y las condiciones operativas de ADR-0026 (presupuesto, formalizar SCCs RGPD). Este ADR
  no enciende la key.
