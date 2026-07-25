# Hallazgos de la investigación de competidores

> **Estado:** BORRADOR PARCIAL (2026-07-25). Las secciones marcadas 🔍 están cerradas por investigación de escritorio + estado real del back. Las marcadas ✍️ se completan tras el teardown hands-on (Tasks 2-9 del runbook). Matriz: `competidores-matriz.md`.

---

## Entregable 1 — Matriz
Ver `competidores-matriz.md` (8 competidores × 4 lentes + anti-patrón).

## Entregable 2 — Lista de robo priorizada  ✍️ (se completa con el teardown)

Junta aquí todos los `[ROBAR: ___]` de la matriz tras el teardown, ordenados por impacto y marcados FOSO / TABLE STAKES.

**Ya claros por desk (confirmar en vivo):**
- **TS** — parseo de confirmación de vuelo por email (TripIt lo hace de rey; table stakes, hay que tenerlo).
- **TS** — escaneo de recibo → itemizar → asignar (Splitwise/Apple Cash; el patrón "toca ítem → asígnalo → auto-suma").
- **ROBAR (activación)** — empezar sin cuenta / fricción mínima para meter al grupo (Tricount).
- _(el resto sale del teardown)_

## Entregable 3 — Los 3 momentos mágicos  🔍 borrador estratégico (validar con el teardown)

Las costuras que NINGUNA app tiene, porque ninguna es un bento. Candidatos al PRIMER flujo del front:

1. **Votar en el chat → entra al itinerario → el gasto se reparte solo.**
   El grupo decide dónde cenar con una votación DENTRO del chat; al ganar, la actividad entra al itinerario del día; cuando se paga, el gasto ya sabe quién estaba y se reparte. Wanderlog no tiene gastos, Splitwise no tiene itinerario, WhatsApp no tiene nada conectado. Solo el bento cierra el círculo.

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
