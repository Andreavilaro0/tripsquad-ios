# Constitución del Front — TripSquad

**Naturaleza:** reglas **duras y vinculantes** para todo el trabajo de front (iOS y, cuando llegue,
Android/web). Análogas a `constitution.md`, de la que es subordinada. **Aplican a QUIEN HAGA EL
FRONT — humano o agente.** No son opcionales: saltarse una fase o una skill obligatoria es motivo
para rechazar el trabajo en revisión.

**Origen:** acordada con Andrea 2026-07-28 vía brainstorming. Norte de producto:
*"se siente premium, no una hoja de cálculo"* (ver `DESIGN.md`).

---

## Pipeline del front — 5 fases con gates

Cada fase tiene un **gate**: no se pasa a la siguiente sin cumplirla. El orden es obligatorio.

### Fase 1 · Descubrimiento UX/UI + comportamiento de usuario
**Gate: no se diseña ni se codifica una pantalla sin esto.**
- **Personas** del squad + **Jobs-to-be-Done** escritos: qué intenta lograr el usuario en esa pantalla.
- **Recorrido heurístico** Krug/Nielsen (skill `ux-heuristics`): puntuar la pantalla 0–10 y listar
  fricciones antes de dar por buena la UX.
- **Agente-usuario:** un agente IA que hace de **usuario real** y "usa" el flujo/prototipo,
  narrando dónde se atasca, qué no entiende y qué toca por error. Su feedback es input, no adorno.
- Skills: `ux-heuristics`, `ios-hig-design` (comportamiento nativo iOS), `jobs-to-be-done`,
  `user-story`.

### Fase 2 · Taste / dirección visual
**Gate: aprobado por criterio de diseño (taste), contra `DESIGN.md` + dirección aprobada.**
- **Skills de taste OBLIGATORIAS** (invocarlas, no improvisar):
  - **Taste** (`taste-skill`) — criterio estético.
  - **Impeccable** (`impeccable`) — pulido y refinamiento visual.
  - **Emil Kowalski** — craft de UI/micro-interacción/animación (ver catálogo externo, R3).
  - `ui-ux-pro-max`, `frontend-design`, `ios-hig-design`, `refactoring-ui`,
    `visual-hierarchy` / `web-typography`, y `dataviz` para cualquier gráfica.
- Construir **contra `DESIGN.md`** y la **dirección aprobada** (dashboard de tarjetas limpio,
  ver `docs/design/figma-v7-build-spec.md` §8d y `design/ia-inicio/`). **Referenciar el "pincel"**
  (diseño en Pencil, `design/pantallas/`) como lenguaje base.
- **Regla anti-slop** (`DESIGN.md §anti-slop`): nada que "grite IA".

### Fase 3 · Código
**Gate: los gates de calidad del repo.**
- **Clean Architecture** obligatoria (Presentation/Domain/Data/Infra), SwiftUI puro (ADR-0008).
- Cliente **generado del contrato** (OpenAPI + contrato PowerSync), nunca a mano.
- Gates: `xcodebuild` OK + SwiftLint + `gitleaks` + `semgrep`.

### Fase 4 · Testeo + validación de otra IA
**Gate: nada es "hecho" hasta pasar esto.**
- **Testeo automatizado:**
  - **Accesibilidad:** `axe-core` + `Lighthouse` (skills `accessibility-audit`, `lighthouse-audit`).
  - **Regresión visual:** `reg-suit` / `BackstopJS` (web) o snapshots; en iOS, snapshots de vistas.
  - **Recorridos:** `Playwright` / `webapp-testing` (web) · **`ios-qa`** en simulador (iOS).
  - ⚠️ **Lo automático solo pilla ~57% de los problemas de accesibilidad** → la revisión manual
    y el paso del agente-usuario (Fase 1) son obligatorios, no sustituibles por el linter.
- **Validación de OTRA IA:** lo que escribe un agente lo revisa **otro modelo** (Codex/Gemini),
  igual que el flujo actual del repo (ver `AGENTS.md`, memoria de flujo de PRs).

### Fase 5 · Firma de Andrea
**Gate final.** Andrea aprueba. Ninguna pantalla se da por cerrada sin su firma.

---

## Reglas transversales

### R1 · Desatascarse con las herramientas de pago
Si el que hace el front **se bloquea en un problema de diseño**, DEBE plantearse activamente usar
las herramientas de pago disponibles para desatascarse, en vez de dar vueltas:
- **Higgsfield** — generación IA de imagen/vídeo (explorar direcciones, mockups, referencias;
  probar varios modelos: Nano Banana, GPT Image, etc.). Método probado 2026-07-28.
- **After Effects (AE)** — motion, animación, prototipos de movimiento (MCP conectado).
- **MotionArray** (motionarray.com) — plantillas, stock, motion graphics, presets.

Pensar "¿puede una de estas ayudarme aquí?" es **parte del trabajo**, no un último recurso.

### R2 · Skills obligatorias
El que haga el front (humano o agente) **DEBE invocar las skills de cada fase**. Usar el criterio
propio en lugar de las skills de taste/UX/testeo no está permitido para trabajo que va a firma.

### R3 · Catálogo externo de taste
Referencia viva de las skills de taste: **https://design-skills-joaco.vercel.app**
(Impeccable · Taste · Emil Kowalski). Consultarla cuando se necesite subir el nivel de craft.

---

## Definición de "hecho" (front)
Una pantalla está **hecha** solo cuando: Fase 1 documentada (personas/JTBD + recorrido +
agente-usuario) · Fase 2 con skills de taste invocadas y alineada a `DESIGN.md`/dirección
aprobada · Fase 3 con gates de código verdes · Fase 4 con testeo automatizado + manual + revisión
de otra IA · **Fase 5: firma de Andrea.**
