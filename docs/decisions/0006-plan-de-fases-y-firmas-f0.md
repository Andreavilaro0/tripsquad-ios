# ADR-0006 — Plan de fases del cierre UX/UI + firmas de F0

- Estado: **accepted** (2026-07-10)
- Decisor: Andrea (plan de fases, D1–D3 en /office-hours) · F0 firmada por Claude **por
  delegación explícita de Andrea** ("te dejo a ti todas las decisiones"). Andrea conserva
  derecho de veto: cualquier firma de F0 puede revertirse con un ADR que la reemplace.

## Contexto
Fase design-first con sistema v7 aprobado (ADR-0005), bienvenida cerrada (ADR-0004),
monetización híbrida firmada y un tablero maestro en Pencil con 20 huecos en wireframe.
Riesgo: sin fases, el cierre no converge (bucle histórico de rediseño).

## Decisión 1 — Plan de fases (aprobado por Andrea)
Vía "el río" (por flujo de usuario) + hilo narrativo de Lisboa (MA/LE/SO/DA · jun 2026 · €985):
**F0** firmas de arranque → **F1** Inicio por nº de viajes → **F2** Crear+Brújula+Paywall →
**F3a** viaje: Hub/Planes/mapa → **F3b** viaje: Chat/Gastos/Fotos/Votos + cierre de viaje →
**F4** soporte/modos/offline/accesibilidad → **F5** sellado (DESIGN.md, ADRs, .pen, commit,
handoff). Cada fase: abre firmando sus ◆ con demos concretas, produce, cierra con chip ✓ +
DESIGN.md. Fecha objetivo 2026-07-31 (~4 sesiones/semana; se revisa en checkpoint F3a/F3b).
Doc completo: `~/.gstack/projects/TripSquad-iOS/andreaavila-main-design-20260710-fases-cierre-uxui.md`.

## Decisión 2 — Firmas de F0 (por delegación)
1. **Acento micro definitivo: Lavanda `#9782B8`.** Razón: proviene de la ref favorita de
   Andrea, sobrevivió 3 versiones de prototipo como default sin objeción, y es acento
   "inusual" (regla editorial). Burdeos `#6E1423` queda exclusivo del momento de compra.
2. **Componentes v1 (16):** sello holográfico, split-flap, mapa espina-dorsal, fly-to+pin→
   tarjeta, pin sonar, arcos convergentes, avatares squad+glow (opt-in), donut tocable+
   simplificar+confetti, votos swipe, text blast, Brújula viva (shimmer/ripple/gooey), tab bar
   squash, botones squishy, Live Activity, recap de cierre, transición concéntrica.
   **Aplazados explícitos:** globo, scrubbing, compare-slider, text explode, widget, paleta
   por destino. Razón del corte: la escasez es lo premium; cada módulo recibe 1 hero + micro-
   física, nada más. Dependencias MIT aprobadas: ConfettiSwiftUI, SwiftUI-Shimmer,
   SwiftUICharts, ClusterMap. Pow descartado (licencia de pago).
3. **Efectos firma + accesibilidad:** sello bronce, springs 0.2/0.4·0.3/0.8·0.4/1.0, tilt ±5°,
   grain ≤12%, borde-glow solo celebraciones, confetti solo 3 hitos (pago, liquidación,
   cierre). Todo efecto con versión Reduce Motion; dorados solo sobre tinta (AA).
4. **Logo: R3-logo3 firmado como isotipo base.** Refinamiento bespoke post-F5; no bloquea.
5. **El .pen SE GUARDA en `TripSquad-iOS/design/`.** Desbloquea fotos reales + shader desde
   F1. Paso mecánico pendiente de Andrea (Cmd+S en la app Pencil hacia esa ruta); hasta
   entonces, placeholders con sustitución 1:1 (sin reabrir fases). Fuente de fotos reales:
   las de `design/bienvenida/` + nuevas Gemini bajo `prompt-estilo.txt`.
6. **Checklist reconciliado: 20 huecos WF** (4 en sección 00, 1 en 01, 2 en 02, 5 en 03,
   3 en 04, 5 en 05 — más las vistas ya en dirección v7 que se afinan en su fase).
   "Relleno" = flujo completo + estados clave en v7 final.

## Consecuencias
- F1 puede arrancar de inmediato; P3 (componentes antes que pantallas) queda satisfecha para
  F1/F2. Las ◆ de mapa (F3a) y modo noche (F4) siguen abiertas a propósito.
- Cambiar cualquier firma de F0 = ADR nuevo que reemplace a este (append-only).
