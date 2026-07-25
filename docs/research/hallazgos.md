# Hallazgos de la investigación de competidores

> **Estado:** BORRADOR PARCIAL (2026-07-25). Las secciones marcadas 🔍 están cerradas por investigación de escritorio + estado real del back. Las marcadas ✍️ se completan tras el teardown hands-on (Tasks 2-9 del runbook). Matriz: `competidores-matriz.md`.
>
> **Teardown hands-on WEB hecho (2026-07-25):** Wanderlog ✅, Splitwise ✅, Mindtrip ✅ (Chrome real), Apple Cash ✅ (specs). **Pendientes de MÓVIL** (Andrea, no reproducibles headless): parseo de vuelo de TripIt, receipt-scan de Splitwise, arranque-sin-cuenta de Tricount, wedge "quién reservó" de la app de grupo, y la encuesta de WhatsApp.

---

## ⭐ HALLAZGO CLAVE (afila la estrategia) — Mindtrip es un "casi-bento"

El teardown movió la tesis. **Mindtrip NO es un chat de IA genérico**: integra group chat + itinerario + IA + recibos + colaboración en vivo, y su IA genera itinerarios de **calidad alta** (probado: 3 días en Lisboa clusterizados por barrio, con mapa y auto-add, en ~20s). Esto **derriba la suposición cómoda** de "somos un bento y ellos no".

→ **El foso de TripSquad se estrecha y se AFILA a tres cosas concretas** que ni Mindtrip ni nadie tiene juntas:
1. **Liquidación real (settle):** "quién debe a quién" + saldos + settle. Mindtrip solo *almacena* recibos; Splitwise lo hace pero fuera del viaje. **Nadie tiene settle DENTRO del viaje conectado a votos/itinerario.**
2. **Decisión estructurada (votación con resultado):** un voto que produce una decisión y se propaga (→ itinerario → gasto). Los demás tienen chat + sugerencias de IA, no un voto con veredicto.
3. **Europa + no-vender-reservas:** Apple Cash bill-split es solo-EEUU; Mindtrip monetiza empujando hoteles/tours (afiliación). Hueco: mercado europeo + una Brújula que aconseja sin vender.

**Implicación para el front:** el pitch NO es "todo en una app". Es **"la única app donde la decisión del grupo se convierte sola en plan y en cuentas saldadas, en Europa, sin venderte reservas".** El settle y la votación estructurada son los pilares que hay que enseñar primero.

---

## Entregable 1 — Matriz
Ver `competidores-matriz.md` (8 competidores × 4 lentes + anti-patrón).

## Entregable 2 — Lista de robo priorizada  ✍️ (se completa con el teardown)

Junta aquí todos los `[ROBAR: ___]` de la matriz tras el teardown, ordenados por impacto y marcados FOSO / TABLE STAKES.

**Confirmados en hands-on (2026-07-25):**
- **TS / ROBAR (split)** — Splitwise: la **frase editable en lenguaje natural** "Pagado por _X_ y dividido _[a partes iguales / exactas / % / cuotas]_ ($Y/persona)" con chips inline. Claridad, no hoja de cálculo. Es el listón de UX del split del bento.
- **TS (Brújula)** — Mindtrip: **generación IA de itinerario clusterizado-por-día con auto-add al viaje y mapa vivo**. La Brújula debe igualar esta calidad (y superar con contexto de grupo real).
- **ROBAR (itinerario/"quién hizo su parte")** — Wanderlog: **vista dual lista↔mapa + atribución por persona** ("added by Nancy/Debby/You" en cada pin). Conecta directo con el instinto "quién ya reservó".
- **ROBAR (activación)** — Wanderlog confirma que se puede crear viaje **con 0 cuenta** ("Skip and sign up later") y dar valor antes de pedir registro. (Tricount no-account = pendiente de verificar en móvil.)

**Ya claros por desk (pendiente confirmar en MÓVIL):**
- **TS** — parseo de confirmación de vuelo por email (TripIt lo hace de rey; table stakes). No reproducible headless (necesita cuenta + email real).
- **TS** — escaneo de recibo → itemizar → asignar (Splitwise/Apple Cash; el patrón "toca ítem → asígnalo → auto-suma"). En Splitwise es **solo-móvil**.

## Entregable 3 — Los 3 momentos mágicos  🔍 borrador estratégico (validar con el teardown)

Las costuras que NINGUNA app tiene, porque ninguna es un bento. Candidatos al PRIMER flujo del front:

1. **Votar en el chat → entra al itinerario → el gasto se reparte solo.**  ⭐ **PRIORIDAD 1 tras el teardown** (es exactamente el foso afilado: decisión estructurada + settle en contexto).
   El grupo decide dónde cenar con una votación DENTRO del chat; al ganar, la actividad entra al itinerario del día; cuando se paga, el gasto ya sabe quién estaba y se reparte. Corrección post-teardown: **Wanderlog SÍ tiene gastos** (módulo Budget con group balances) y **Mindtrip tiene chat+itinerario+IA**, pero **ninguno conecta un VOTO con resultado → itinerario → settle**; sus gastos viven aparte del contexto de la decisión. Splitwise no tiene itinerario, WhatsApp no tiene nada conectado. Solo el bento cierra este círculo concreto (voto→plan→cuentas).

2. **Recibo → split en contexto (y en Europa).**
   Foto al recibo, marcas lo que comió cada uno, se reparte. Igual que Apple Cash iOS 27 PERO: funciona en Europa (Apple Cash es solo-EEUU) y sabe que estáis de viaje juntos, así que el saldo entra al settle del grupo, no a un cobro suelto.

3. **Tablero "quién ya reservó".**
   Un tablero vivo del viaje: ✅ Iván reservó su vuelo · ⏳ Sara pendiente · ✅ hotel confirmado. La ansiedad #1 del viaje de grupo, sin dueño en el mercado. Convierte "¿habéis reservado todos?" (20 mensajes en WhatsApp) en un vistazo.

## Entregable 4 — Quick wins que nos faltan  ✍️ (se completa con el teardown)

Junta aquí todos los L4 de la matriz, ordenados por impacto ÷ esfuerzo (S/M). Es el relleno barato que se ataca en paralelo a los flujos grandes.

---

## Dependencias FRONT → BACK  🔍 CERRADO (estado del back a 2026-07-25)

Lo que hay que ver ANTES de construir cada pieza de front. Cuatro de las piezas más atractivas **no tienen back todavía** — son trabajo de back nuevo, no solo de front.

| Pieza de front | Estado del back | Qué hace falta antes |
|---|---|---|
| Onboarding, itinerario, votaciones, gastos+settle (suggestion/confirm) | **hecho** (bento 6/6 en develop) | nada de back; a construir front directo |
| **Galería de fotos que sube de verdad** | **stub** | bead **7n3** (FotoStorage real R2/S3/Supabase) |
| **Brújula que responde de verdad** | **stub** | bead **3dk** (AsistenteIA real Anthropic) |
| **Chat en vivo** | back es *polling* (GET messages con cursor), no realtime | decidir: ¿v1 con polling aceptable, o realtime = hueco de back nuevo? |
| **Recibo → split** (momento mágico 2) | **no existe** | **bead a crear**: endpoint de OCR/itemización de recibo |
| **Tablero "quién reservó"** (momento mágico 3) | **no existe** | **bead a crear**: modelo de estado de reserva por persona |
| **Historial de ediciones** (si entra en front) | parcial | bead **p4b** |
| Cualquier front en producción | — | infra: bloqueante #2 (hosting/Pi) + Render `SUPABASE_URL` |

**Beads a crear tras la investigación** (si los momentos mágicos 2 y 3 sobreviven al teardown):
- OCR/itemización de recibo (back del momento mágico 2).
- Estado de reserva por persona (back del momento mágico 3, el wedge).

No se crean ahora para respetar el "primero la investigación": si el teardown confirma que valen la pena, se abren antes de construir su pantalla.

---

## Regla de oro (recordatorio de la sesión)
El instinto de Andrea ("quién ya reservó", "no confuso") pesa más que cualquier feature de un competidor. La investigación CONFIRMA y PRIORIZA ese instinto, no lo reemplaza. Si la matriz sugiere copiar algo que le chirría, gana el chirrido.
