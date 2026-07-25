# ADR-0025 — Recibo → split: itemización on-device, back solo hace la cuenta

- **Fecha:** 2026-07-25
- **Estado:** accepted
- **Dueña:** Andrea
- **Depende de:** ADR-0011 (motor de saldos), ADR-0012 (camino de escritura idempotente),
  ADR-0018 (onboarding viajes + miembros).
- **Spec:** `docs/superpowers/specs/2026-07-25-recibo-split-on-device-design.md`.

## Contexto

La investigación de competidores (`docs/research/hallazgos.md`, momento mágico #2) identificó
el flujo "foto al recibo → tocas ítems → los asignas → se reparte y entra al settle del grupo",
al estilo Apple Cash iOS 27 pero pensado para Europa y para un grupo de viaje (el saldo entra al
settle compartido, no a un cobro suelto entre dos personas).

La primera decisión de tamaño fue dónde vive el OCR/la itemización del recibo. Se evaluó usar el
tier gratuito de Gemini para hacerlo en el back. Verificando los términos reales de Google
(búsqueda web + Context7, 2026): **el tier gratuito de Gemini entrena con los datos enviados, y
sus términos exigen el modo de pago para usuarios de UE/EEE/UK/Suiza**. TripSquad es
Europa-first y trata dato financiero (importes, quién pagó qué) — el RGPD y la postura de "cero
salida de datos financieros a un tercero sin necesidad" hacen que el free tier no sea viable, ni
redactando el contenido antes de enviarlo. Usar el tier de pago habría metido en esta feature un
gate de coste por uso, una superficie de prompt-injection nueva, y un puerto de IA en el back
solo para esto.

## Decisión

**Todo el OCR y la estructuración del recibo ocurren on-device en el iPhone** (VisionKit /
modelos on-device de Apple). Cero salida de datos del recibo, cero coste por uso, cero gate de
API de pago, cero superficie de prompt-injection en el back. **El back NO parsea recibos**: solo
recibe ítems ya estructurados y asignados por la app, valida sumas (no semántica), y hace la
cuenta del dinero con el motor de reparto ya testeado (ADR-0011).

### `repartoDesdeRecibo` — compone primitivas ya testeadas

`TripSquadDomain/RepartoDesdeRecibo.swift`:

```swift
func repartoDesdeRecibo(items: [ItemRecibo], impuestosMinor: Int64, propinaMinor: Int64) throws -> Reparto
```

donde `ItemRecibo = { importeMinor: Int64, sharers: [MiembroId] }`. No es un motor nuevo: es
composición de las dos primitivas de reparto que ya existían (ADR-0011):

1. **Subtotal por persona** = suma de la parte igual de cada ítem entre sus `sharers`
   (`repartoIgual`). El céntimo sobrante de un ítem compartido cae en el `MiembroId` menor del
   subconjunto (mismo criterio determinista que el resto del motor — nunca "el primero de la
   lista").
2. **Impuestos + propina** se prorratean proporcional al subtotal de cada persona — es
   exactamente `repartoPorPeso` (largest-remainder ponderado, ADR-0011 §3) usando los subtotales
   como pesos. Es el mismo criterio que usa Apple Cash: quien pidió más paga proporcionalmente
   más impuesto/propina, nadie negocia un prorrateo aparte.
3. El resultado es `.exacto([MiembroId: total])`, con `total = subtotal + prorrateo`.

El `importeMinor` del gasto se **deriva**: es la suma de los ítems + impuestos + propina, nunca
se reconcilia contra un "total" que venga por separado del recibo. Esto elimina de raíz la clase
de bug "el total del recibo no cuadra con la suma de sus líneas" — no hay dos números que puedan
discrepar porque solo existe uno, calculado.

### El gasto entra por el pipeline existente

`CasosDeUsoGastos.crearDesdeRecibo` (en `TripSquadExpenses/CasosDeUso.swift`) NO es un camino de
escritura paralelo: calcula el `Reparto` con `repartoDesdeRecibo`, construye un `Gasto` normal
(`.exacto`), y delega en el `crear` ya existente — el mismo que usa un gasto manual. Eso significa
que un gasto desde recibo hereda gratis todo lo que ya tenía `crear`: **replay de idempotencia
antes de re-autorizar** (ADR-0012 §4 — un reintento tras haber sido expulsado del viaje entre
intentos no pierde la escritura ya hecha), el gate de **auth = miembro del viaje** (`not_member`
si no lo es), el gate de **viaje cerrado** (`trip_closed`), y la validación de que las cuotas
cuadran con el importe antes de persistir. El gasto resultante alimenta el settle del grupo
exactamente igual que cualquier otro gasto — no hay un settle "de recibos" aparte.

### Endpoint

`POST /trips/:tripId/expenses/from-receipt`, montado junto al resto de rutas de gastos en
`GastosRoutes.swift` (no es un router/módulo nuevo). Body (`ReciboDTO`): `gastoId`, `pagadoPor`,
`items: [{ importeMinor, sharers }]`, `impuestosMinor`, `propinaMinor`. Requiere
`Idempotency-Key` igual que el resto de POSTs mutantes de la API directa. Un recibo que no
compone un reparto válido (ítem sin sharers, importe negativo, overflow al sumar) se rechaza como
`invalid_receipt` → 422, nunca revienta el proceso.

## Alternativas consideradas

- **OCR/itemización en el back con Gemini (tier gratuito)** — descartada: RGPD + términos de
  Google exigen tier de pago para usuarios UE/EEE/UK/Suiza; habría metido coste-por-uso, un
  puerto de IA nuevo, y superficie de prompt-injection para una feature cuyo valor no depende de
  dónde corre el OCR.
- **OCR en el back con Gemini (tier de pago)** — descartada para v1: viable técnicamente, pero
  añade un gate de gasto en API de pago (regla de "alto riesgo → para y pregunta a Andrea" de
  CLAUDE.md) y un puerto de IA por una feature que on-device resuelve con coste cero y mejor
  privacidad (la foto del recibo ni siquiera sale del teléfono). Queda como opción futura si
  on-device demuestra ser insuficiente en precisión.
- **Reconciliar el importe del gasto contra un "total" que venga en el DTO del recibo** —
  descartada: dos números (el total impreso del recibo vs. la suma de líneas que ve la OCR)
  pueden discrepar por céntimos de redondeo de imprenta o líneas mal leídas; derivar el importe
  siempre desde la suma elimina esa clase de bug en vez de tener que decidir cuál de los dos
  números manda.
- **Camino de escritura paralelo para gastos-desde-recibo (repo/validación propios)** —
  descartada: duplicaría el replay de idempotencia, el gate de auth y el gate de viaje-cerrado que
  ya existen en `crear`, con riesgo real de que diverjan con el tiempo (p. ej. si `crear` gana una
  validación nueva y `crearDesdeRecibo` se queda atrás). Construir el `Gasto` y delegar en `crear`
  es más barato y mantiene una sola fuente de verdad para "qué hace válido un gasto".

## Consecuencias

- El back gana **una sola responsabilidad nueva de verdad**: componer `.igual` + `.porPeso` →
  `.exacto` para un recibo itemizado. Todo lo espinoso de la idea original (LLM, puerto de IA,
  endpoint de parseo, redacción de datos, presupuesto de API) queda fuera del back — vive en la
  app iOS, no es parte de este ADR.
- Determinista → sujeto al mismo gate de **golden vectors** que el resto del motor de saldos (cf.
  bead 0i9): mismos inputs, mismo `.exacto` siempre, en Swift y en el futuro cliente Kotlin.
- **Desviaciones conscientes:**
  1. **~~`sharers`/`pagadoPor ⊆ miembros` no se valida~~ → RESUELTO (bead epb, 2026-07-25).** Tras
     elevarlo a Alta DOS revisores independientes (opus + Codex), se cerró en la misma rama:
     `CasosDeUsoGastos` ahora valida en `crear` **y** `editar` (y por delegación en `crearDesdeRecibo`)
     que `pagadoPor` y **todos** los miembros del reparto (`.igual`/`.porPeso`/`.exacto`) sean
     miembros del viaje; si no → `.rechazado("member_not_in_trip")`. La comprobación va tras el replay
     (que sigue ganando) y tras `autorizar`, antes de persistir. Cierra el hueco tanto para gastos
     normales como para recibo. **Pendiente (defensa en profundidad, sigue en bead epb):** FK/CHECK en
     BD (`expense_shares.member_id`/`paid_by` → `trip_members`), que toca migraciones y datos existentes.
  2. **`ReciboDTO` no lleva campo de divisa** — `importeMinor` es `Int64` en céntimos de la
     divisa de referencia del viaje, sin negociación de moneda. v1 es EUR-only por decisión de
     alcance (la sección "fuera de alcance" del spec); FX/moneda extranjera queda para una
     iteración futura si aparece necesidad real, con su propio ADR.
  3. **El endpoint devuelve 422, no 403, para `not_member` y `trip_closed`.** El spec de esta
     feature pedía 403 para "no eres miembro" / "viaje cerrado". `crearDesdeRecibo` reutiliza a
     propósito el pipeline existente `CasosDeUsoGastos.crear`, cuya ruta mapea todo `.rechazado` →
     422 vía `respuestaDirecta`. Cambiar solo este endpoint a 403 lo dejaría inconsistente con
     `POST /expenses`, que devuelve 422 para estos mismos casos. El fix correcto es transversal
     (los 8 caminos de escritura de Gastos deberían devolver 403 de forma uniforme) y ya está
     registrado como **bead 55x** ("Gastos devuelve 422 donde los otros 7 devuelven 403"). Este
     endpoint se queda intencionalmente consistente con el pipeline de gastos (422) hasta que 55x
     los arregle todos juntos; el test de ruta `noMiembro422` documenta el comportamiento actual y
     será actualizado por 55x.
- **Cobertura de tests / deferidos:**
  a. `repartoDesdeRecibo` está cubierto por tests unitarios en Swift con mapas exactos esperados,
     pero NO se añadió al generador de golden vectors cross-language (bead 0i9) — riesgo bajo
     porque es composición pura de `repartoIgual`/`repartoPorPeso`, que ya son golden, y delega en
     el `crear` ya testeado.
  b. Los tests de ruta comprueban el status HTTP, no el efecto end-to-end sobre el settle (el test
     del caso de uso sí comprueba el `importeMinor` persistido + `.exacto`).
  c. Caso límite: un recibo cuyos ítems son todos 0 pero con impuestos/propina > 0 se rechaza como
     `invalid_receipt` (422), porque no hay subtotal positivo sobre el que prorratear — es
     determinista y defendible.
- Fuera de alcance v1 (sin tareas abiertas aquí): adjuntar la foto del recibo al gasto (necesita
  `FotoStorage` real, bead 7n3 — en el híbrido on-device la imagen ni siquiera sale del móvil, así
  que no es urgente), moneda extranjera/FX, y sugerencia automática de asignación de ítems (futuro
  front).
