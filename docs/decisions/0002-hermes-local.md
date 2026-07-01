# ADR-0002 — Instalar Hermes local (Ollama), revirtiendo el aplazamiento

- **Fecha:** 2026-07-01
- **Estado:** accepted
- **Dueña:** Andrea

## Contexto
En la sesión de estrategia (office-hours, 2026-06-30) se decidió **aplazar** Hermes y n8n a
Fase E, por considerarlos premature complexity: un sistema agéntico custom para construir la
app, con un modelo más débil que los tres frontier ya disponibles (Claude/Codex/Gemini). Quedó
escrito así en TASKS.md y en el design doc.

Andrea decidió, aun así, instalar Hermes local ahora. Como dueña del proyecto, su decisión
prevalece. Este ADR registra la reversión de forma visible (no en silencio), que es la
disciplina append-only del proyecto.

## Decisión
Instalar Hermes local ya, vía **Ollama** + modelo **hermes3:8b**, con almacenamiento en el
disco externo (DiscoAndrea). Ver `docs/setup/hermes.md`.

## Alternativas consideradas
- **Mantener el aplazamiento** — descartado: la dueña quiere probarlo ahora.
- **Hermes 35B/405B** — no cabe en 16 GB de RAM (M4 Air). Descartado por hardware.
- **LM Studio en vez de Ollama** — Ollama es más simple en CLI y se integra con Codex `--oss`.

## Consecuencias
- Se gana un modelo local, gratis y privado, enchufable a Codex (`--oss`).
- Coste: ~5 GB en disco externo; un modelo más débil que los auditores frontier. No sustituye a
  Codex/Gemini como revisores principales.
- Dependencia operativa: Ollama necesita el disco externo montado (ver launcher).
- Si más adelante se decide retirarlo, se hace con un ADR nuevo que supersede a este.
