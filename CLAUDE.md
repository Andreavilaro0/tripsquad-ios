# TripSquad — Guía de trabajo (CLAUDE.md)

Este archivo se carga al inicio de cada sesión. Es el control: las reglas que todo
agente obedece. Léelo antes de tocar nada.

## Qué es TripSquad
App iOS para grupos de amigos que viajan juntos. Todo el viaje en un solo lugar (bento):
chat, itinerario, gastos + liquidación, votaciones, fotos y Brújula IA. No es un gestor de
viajes; es la compañía de viaje del squad. La apuesta: el valor está en la integración (el
bento), no en las features sueltas.

## Estado actual
Fase: **pre-código, design-first.** El código anterior se borró a propósito (se daba vueltas
rediseñando en mitad de código). Ahora se decide y diseña ANTES de codificar. Ver `CONTEXT.md`.

## Reglas inmutables (constitution)
Ver `constitution.md`. Resumen:
1. **Una marca: TripSquad.** (ADR-0001). No "Travesía", no "Avilastudio".
2. **Design-first:** nada se codifica sin diseño + spec aprobados.
3. **Decidido > perfecto, con fecha.** Cada fase es timeboxed.
4. **Las decisiones no se re-litigan:** se registran como ADR append-only en `docs/decisions/`.
   Para cambiar una decisión aceptada, escribe un ADR nuevo que la reemplace (supersede); no
   edites ni borres el viejo.
5. **Clean Architecture obligatoria** cuando empiece el código (Presentation/Domain/Data/Infra).
6. **Ningún API se usa sin traer su doc real vía Context7** (anti-alucinación).
7. **Higiene de contexto:** no pasar del ~60% de la ventana; `context-save` antes de compactar.

## Roles y control de agentes
- **Andrea = líder y dueña.** Decide, aprueba, pone el gusto.
- **Claude = orquestador.** Coordina; subagentes con herramientas acotadas (menor privilegio).
- **Gates por niveles (human-in-the-loop):**
  - *Rutina* (agente solo, bajo guardrails): formateo, tests, código que pasa los gates.
  - *Alto riesgo → PARA y pregunta a Andrea:* arquitectura, alcance, dirección de diseño,
    borrar/sobrescribir, dependencias nuevas, gasto en APIs de pago.
  - *Validación:* lo escribe un agente, lo revisa OTRO modelo (Codex/Gemini), Andrea firma.

## Gates de calidad (cuando haya código)
Nada es "hecho" hasta: `xcodebuild` OK + SwiftLint + `gitleaks` (secretos) + `semgrep` (SAST)
+ revisor de modelo distinto + aprobación de Andrea. Tools ya instalados en la máquina.

## Sistema de diseño
Cuando exista `DESIGN.md`, léelo SIEMPRE antes de cualquier decisión visual. Hoy aún no está
finalizado; el WIP vive en `docs/design/design-direction-WIP.md`. Norte memorable acordado:
**"se siente premium, no una hoja de cálculo".**

## Documentación
Estructura Diátaxis (tutorial / how-to / reference / explanation). Docs en git, versionados
con el código. Changelog con Conventional Commits cuando arranque el código.

## Skill routing (gstack)
Cuando la petición encaje con una skill, invócala. Clave:
- Idea/brainstorm → `/office-hours`
- Estrategia/alcance → `/plan-ceo-review`
- Diseño → `/design-consultation` o `/plan-design-review`
- Arquitectura → `/plan-eng-review`
- Spec → `/spec`
- Bugs → `/investigate`
- QA → `/qa`
- Review de código → `/review` · Seguridad → `/cso`
- Guardar/retomar contexto → `/context-save` / `/context-restore`

## Herramientas (estado)
Instaladas y listas: git, gh, swift, xcodebuild, node, npm, bun, codex, gemini, semgrep,
gitleaks, trivy. MCP conectados: Context7, Figma, refero, Pencil, Canva, Vercel, Notion,
Gmail, etc. Aplazado: gbrain (memoria buscable — se instala DESPUÉS del diseño).
