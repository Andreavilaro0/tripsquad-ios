# ADR-0005 — App: sobriedad blanca + Liquid Glass claro (v7)

- **Fecha:** 2026-07-09
- **Estado:** accepted
- **Dueña:** Andrea

## Contexto
Con la marca y la bienvenida cerradas (ADR-0004, mundo cálido de criaturas glow), tocaba la
estética de la app en sí: "sobrio, premium, liquid glass, pocos colores, interacciones".
Se iteró con un prototipo interactivo (HTML tocable, mismo material que iOS regala con
`.glassEffect`): v2 con acentos llenos fue rechazada por exceso de color; v4 osciló a oscuro
casi monocromo (ref "trip with crew"); Andrea pidió "una sobriedad más blanca" (refs Onda,
Invoice, y su ref crema de countdown/gastos) y después "pero glass liquid".

## Decisión
La app TripSquad usa la **clave clara v7**: fondo crema `#F5F1E9`, foto cinemática que se
**funde en bruma** hacia el papel (nunca cortada), **sans ligera** (SF Pro 300–600, sin serif
dentro de la app), contenido en tarjetas de **tinte sólido** blanco, y **Liquid Glass claro
solo en la capa de controles** (chips, countdown de 3 celdas, sheet, tab bar) con borde
especular. **Acento en micro-dosis, exactamente 4 sitios** (puntito de estado, check,
cifra de deuda, punto de tab activa); el acento jamás rellena botones. Dinero en calma:
recibo papel `#FBF7EF` + cifras mono. Reglas completas y tokens en DESIGN.md v7.

Prototipo de referencia (interacciones incluidas: sheet, votar, recibo desplegable, tabs,
selector de acento): https://claude.ai/code/artifact/5e412cec-aaef-4c16-ba35-a0a5edb82e58

Andrea aprueba asumiendo que el material nativo del simulador lo mejorará ("se verá mejor
en el simulador, así que sí, apruebo").

## Alternativas consideradas
- **v2 vidrio oscuro con acentos llenos** (avatares de colores, botón «Votar» relleno,
  serif editorial) — rechazada: "me falta más sobriedad".
- **v4 oscuro cinemático casi monocromo** — gustó como sobriedad pero Andrea pidió clave
  blanca; queda como **candidato a modo noche** (no firmado).
- **Serif editorial dentro de la app** — descartada: choca con la sobriedad; la personalidad
  tipográfica vive en la marca/bienvenida.
- **Acento por elegir**: candidato por defecto Lavanda `#9782B8`; quedan 8 alternativas
  conmutables en el prototipo. Pendiente de firma final.

## Consecuencias
- DESIGN.md actualizado a v7 (tokens claros + receta del vidrio claro + reglas 1–7).
- Contraste de marca deliberado: bienvenida cálida (criaturas glow sobre noche) → app en
  papel sobrio. La transición bienvenida→app es un momento de diseño pendiente.
- Siguiente: rodar el sistema a Chat, Planes, Gastos y Fotos (prototipo + Pencil).
- El acento final y el modo noche se firmarán con ADRs o anotación en DESIGN.md cuando
  Andrea decida.
- Cuando arranque el código: `.glassEffect` nativo, respetar Reduce Transparencia/Motion.
