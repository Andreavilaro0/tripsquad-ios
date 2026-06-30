# Decisiones (ADR)

Registro de decisiones append-only. Cada decisión importante (marca, alcance, diseño,
arquitectura, dependencias) es un archivo numerado: `0001-...md`, `0002-...md`, etc.

## Reglas
- **Append-only.** No edites ni borres una decisión `accepted`.
- **Cambiar de idea = nuevo ADR** que reemplaza al viejo (`supersedes`), enlazándolos. El
  viejo queda con estado `superseded` y un puntero al nuevo. El historial del pensamiento se
  conserva.
- Cada ADR nombra a su dueña (Andrea) y su estado: `proposed` / `accepted` / `superseded`.
- Usa `_TEMPLATE.md` como base.

## Por qué
El bucle que mató el intento anterior fue re-litigar decisiones en silencio. Aquí, reabrir
una decisión cuesta un registro fechado y visible. Eso es el antídoto.
