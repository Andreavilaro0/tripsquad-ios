# ADR-0003 — Dirección de diseño: editorial minimal cálido

- **Fecha:** 2026-07-03
- **Estado:** accepted
- **Dueña:** Andrea

## Contexto
El diseño es el mayor dolor histórico del proyecto: "nada convencía" por falta de restricciones,
no de iteración. La fase design-first exige decidir la dirección visual ANTES de codificar. En
`/design-consultation` se recorrió: norte memorable, referencias de Andrea (vidrio/aurora + planner
cinematográfico), investigación anti-IA (Perplexity), y minado de apps reales (Retro, Partiful,
Airbnb). Andrea rechazó explícitamente gradientes, la rejilla constante de tarjetas y el exceso de
color. La dirección se validó contra una app real y querida (**Retro**), que hace exactamente esto.

## Decisión
La dirección de diseño de TripSquad es **editorial minimal cálido**: fotografía art-dirigida a
sangre + tipografía serif confiada (Fraunces) + lista editorial con líneas finas + firma editorial,
sobre una paleta de 3 (papel `#F7F2EA`, tinta `#1A1714`, acento óxido `#C06A22`), con el **doble
registro** (social cálido / dinero en calma). El sistema completo vive en `DESIGN.md`.

## Alternativas consideradas
- **Vidrio/aurora con gradientes y tintes** (primeras variantes) — descartado: Andrea rechazó los
  gradientes y el exceso de color; olían a "hecho con IA".
- **Bento de tarjetas iguales** — descartado: cliché de IA; se sustituye por jerarquía editorial.
- **Direcciones "print/editorial" y "suizo" abstractas** (propuestas iniciales) — descartadas antes
  de mockups; las referencias visuales de Andrea apuntaban a foto + serif + aire, no a print puro.

## Consecuencias
- Se cierra la fase design-first: hay `DESIGN.md` gobernante. Todo código futuro debe respetarlo;
  QA debe marcar cualquier desviación.
- Reglas anti-slop explícitas (colores/fonts/estilos prohibidos) en `DESIGN.md` +
  `referencia-anti-slop.md`.
- Quedan dos tareas de diseño REAL (no bloquean el arranque, pero separan preview de producto):
  fotografía con dirección de arte, y wordmark + iconografía bespoke.
- Siguiente fase real: alcance MVP (`/plan-ceo-review`) y luego arquitectura (`/plan-eng-review`).
- Si más adelante se cambia la dirección, se hace con un ADR nuevo que supersede a este; no se edita.
