# Diseño — Recibo → split en contexto (on-device)

> **Estado:** APROBADO en diseño (Andrea, 2026-07-25). Pendiente de convertir en plan (writing-plans).
> **Origen:** `docs/research/hallazgos.md` — momento mágico #2 (recibo-en-contexto, estilo Apple Cash iOS 27 pero en Europa). Segunda de las 2 piezas del FOSO. La primera (wedge "quién reservó") tiene su propio spec: `2026-07-25-wedge-reserva-por-persona-design.md`.
> **Alcance:** SOLO back (Swift). El OCR/itemización y la UI de asignar viven en la app iOS.

## Goal

Dar el flujo "foto al recibo → tocas ítems → los asignas → se reparte y entra al settle del grupo", como Apple Cash iOS 27 PERO funcionando en Europa y sabiendo que estáis de viaje juntos (el saldo entra al settle del grupo, no a un cobro suelto). Es el momento mágico #2 del foso.

## Decisión que define el tamaño: OCR + estructuración ON-DEVICE

Tras verificar los términos reales de Google (búsqueda web + Context7, 2026): el **tier gratuito de Gemini entrena con los datos y sus términos exigen modo de pago para usuarios de UE/EEE/UK/Suiza**. TripSquad es Europa-first con dato financiero y RGPD serio → el free tier NO es viable, ni con redacción.

Decisión (Andrea): **todo el OCR y la estructuración ocurren on-device en el iPhone** (VisionKit / modelos on-device). Cero salida de datos, cero coste, cero gate de API de pago, cero superficie de prompt-injection. **El back NO parsea recibos.**

Consecuencia: el back se queda con **una sola responsabilidad nueva** — recibir ítems ya estructurados + asignados y computar el split en el dominio testeado. Todo lo espinoso (LLM, puerto de IA, endpoint de parseo, redacción, presupuesto) desaparece del back.

## Contrato

La app manda **estructura**; el back valida **sumas** (no semántica) y hace la **cuenta del dinero**.

- La app es dueña de: OCR del recibo, detección de líneas/impuestos/propina, y la UI de "toca el ítem → asígnalo".
- El back recibe importes en **Int64 (céntimos de la divisa de referencia)**, ya estructurados.

## Componentes de back (siguen el molde existente)

### 1. Dominio — `repartoDesdeRecibo(...)`

Función pura en `TripSquadDomain` que compone primitivas YA testeadas (ADR-0011):

`repartoDesdeRecibo(items:[Item], impuestosMinor: Int64, propinaMinor: Int64) -> Reparto.exacto` donde `Item = { importeMinor: Int64, sharers: [MiembroId] }`.

- **Subtotal por persona** = Σ de sus ítems propios + su parte igual de cada ítem compartido. El céntimo sobrante de un ítem compartido se asigna determinista por orden de `MiembroId` (misma filosofía ADR-0011).
- **Impuestos + propina** = prorrateo proporcional al subtotal de cada uno → es exactamente `Reparto.porPeso([MiembroId: subtotal])` (largest-remainder ponderado, ADR-0011 §3). Se reusa tal cual.
- **Total por persona** = subtotal + prorrateo. Devuelve `.exacto([MiembroId: total])`.
- `importeMinor` del gasto = Σ ítems + impuestos + propina (se **deriva**, no se reconcilia con ningún "total" externo → mata de raíz el bug de descuadre).

Determinista → **golden vectors** (como el motor de settle), gate de CI Swift + Kotlin (cf. bead 0i9).

### 2. Caso de uso — `crearGastoDesdeRecibo`

En `TripSquadExpenses` (o extensión de `CasosDeUsoGastos`). Auth y reglas:
- Auth base: **miembro del viaje**. `noAutorizado` → 403 (consistente con los 7 módulos, no 422 como el bug de Gastos, bead 55x).
- **Viaje cerrado** → solo lectura (`viajeCerrado`).
- **Validación:** todos los importes Int64 ≥ 0; cada ítem con ≥ 1 sharer; sharers ⊆ miembros del viaje; `pagadoPor` es miembro. Entrada inválida → 422 (`reglaViolada`), nunca revienta.
- Crea un `Gasto` normal (id de cliente, `pagadoPor`, `importeMinor` derivado, `reparto: .exacto`) → entra por el mismo camino que un gasto manual → alimenta el settle.

### 3. Endpoint — `POST /trips/:tripId/expenses/from-receipt`

Body: `{ pagadoPor, items: [{ importeMinor, sharers: [MiembroId] }], impuestosMinor, propinaMinor }`.
- Reusa la ruta de gastos existente (`GastosRoutes.swift`) como variante, no un módulo nuevo.
- Idempotencia: si trae `Idempotency-Key`, mismo tratamiento que el resto de POSTs mutantes (cf. bead 379, 00i — la key necesita clientId).

## Casos límite

- **Ítem sin sharers** → `reglaViolada` (422).
- **Sharer que no es miembro** (o `pagadoPor` no miembro) → `noAutorizado`/`reglaViolada` sin fuga de existencia (ADR-0018/0019).
- **Importe negativo / overflow al sumar** → error de dominio (`importeNegativo` / `saldoFueraDeRango`, ya existen), 422, nunca caída (P1 de la revisión integrada).
- **Impuestos y propina = 0** → válido; el reparto es solo por ítems.
- **Un solo participante** → válido; se lleva todo.

## Fuera de alcance v1

- **OCR / itemización** → vive en la app iOS (on-device). El back no lo toca.
- **Adjuntar la foto** del recibo al gasto → necesita FotoStorage real (bead 7n3). Aparte. En el híbrido on-device la imagen ni siquiera sale del móvil.
- **Moneda extranjera** (recibo ≠ divisa de referencia) → FX vive en la frontera (futuro). v1 asume divisa de referencia; la app avisa si detecta otra.
- **Sugerir asignación automática** ("esto seguro es de Iván") → futuro, front.

## Tests (estructura actual: dominio / expenses / servicio / integración)

- **Golden vectors** de `repartoDesdeRecibo`: céntimos impares, ítems compartidos entre subconjuntos, una sola persona, impuesto/propina cero, prorrateo proporcional con pesos desiguales. Paridad Swift/Kotlin (bead 0i9).
- **Caso de uso** `crearGastoDesdeRecibo`: matriz de auth (miembro/no-miembro/viaje cerrado), validación (ítem sin sharer, importe negativo, sharer no-miembro), y que el `importeMinor` derivado cuadra con `.exacto`.
- **Ruta**: 403/422 correctos, idempotencia con `Idempotency-Key`.
- **Integración**: end-to-end — POST from-receipt → el gasto aparece en la lista y el settle refleja los nuevos saldos.

## Dependencias

- Reusa: `Gasto`, `Reparto` (`.igual`/`.porPeso`/`.exacto`), `CasosDeUsoGastos`, la infra de auth (`Contexto`/`Auth`), y el gate de golden vectors (bead 0i9).
- **No** depende de: LLM/IA, FotoStorage, APIs de pago, ni del wedge. Independiente del otro spec del foso.

## Beads

- Cerrar el "bead a crear (OCR/itemización de recibo)" de hallazgos.md: **reencuadrado** — el OCR es on-device (front), el back es solo `repartoDesdeRecibo` + endpoint. Crear el bead de back apuntando a este spec.
