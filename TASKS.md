# TASKS — TripSquad

## Ahora (siguiente sesión)
- [ ] **Diseño visual** (retomar `/design-consultation`): ver "riesgos más salvajes" → elegir
      UNA dirección → generar 3 mockups → escribir `DESIGN.md` → registrar **ADR-0002 (dirección
      de diseño)**. Es el mayor dolor histórico; es la prioridad.

## Pronto
- [ ] Re-marcar docs heredados: "Travesía" → "TripSquad" en `docs/travesia-*` (y renombrar archivos).
- [ ] Consolidar `product-overview` + `navigation-map` en un spec vivo gobernante.
- [ ] `/plan-ceo-review` → decidir alcance MVP v1 (¿bento completo o subconjunto para el primer
      viaje de prueba? ¿Brújula IA en v1 o aplazada?).
- [ ] Confirmar auth de auditores: `codex` y `gemini` logueados (CLIs ya instalados).

## Después del diseño
- [ ] Instalar gbrain (memoria buscable): `bun install -g github:garrytan/gbrain` + `/setup-gbrain`.
- [ ] `/plan-eng-review` → arquitectura (Clean Architecture).
- [ ] Decidir backend (el previo era Supabase) y re-evaluarlo.

## Cuando arranque el código (gates)
- [ ] Pre-commit hooks: xcodebuild + SwiftLint + gitleaks + semgrep (tools ya instalados).
- [ ] CI GitHub Actions.
- [ ] Conventional Commits + changelog.

## Aprobado, en cola
- [ ] Protocolo de auditoría multi-modelo: `docs/AUDIT.md` + `scripts/audit.sh` (Codex + Gemini
      en solo-lectura sobre cambios staged) + ADR. Aprobado 2026-06-30; pendiente de escribir.

## Aplazado (Fase E / post-usuarios) — no tocar ahora
- n8n como sistema agéntico custom (premature; reabrir solo si el trabajo se divide en flujos
  paralelos). Posible encaje futuro: backend de la Brújula IA.
- my-virtual-office (github.com/eliautobot/my-virtual-office): dashboard 2D para VER a los
  agentes (soporta Claude/Codex/Hermes). Premio, no base: montar cuando haya agentes
  trabajando de verdad en TripSquad (post-diseño/código). Hoy no hay nada que ver.
- (Hermes YA NO está aplazado: instalado local vía Ollama — ver ADR-0002 y docs/setup/hermes.md.)
- Bloqueadores de lanzamiento iOS: cuenta Apple Developer, política de privacidad, borrado de
  cuenta funcional, StoreKit product IDs (para premium).

## Hecho
- [x] 2026-06-30 Sistema operativo del proyecto definido (office-hours, design doc aprobado).
- [x] 2026-06-30 Marca decidida: TripSquad (ADR-0001).
- [x] 2026-06-30 Base del repo: git init (main) + CLAUDE.md + constitution.md + CONTEXT.md +
      docs/decisions + WIP de diseño + handoff.
