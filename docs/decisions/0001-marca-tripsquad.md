# ADR-0001 — Marca: TripSquad

- **Fecha:** 2026-06-30
- **Estado:** accepted
- **Dueña:** Andrea

## Contexto
El proyecto arrastraba tres nombres mezclados en código y docs: "Travesía", "TripSquad"
(nombre del repo) y "Avilastudio". La ambigüedad de marca es deuda: confunde a agentes,
documentación y futura tienda. Decidir el nombre es el primer acto del sistema operativo
(decidir y no re-litigar).

## Decisión
La app se llama **TripSquad**.

## Alternativas consideradas
- **Travesía** — branding de los docs heredados (web/product-overview). Se descarta como
  nombre de la app; queda obsoleto.
- **Avilastudio** — era el studio/bundle id (`com.avilastudio.travesia`), no el nombre de
  producto. No aplica como marca de la app.

## Consecuencias
- Todo el material heredado marcado "Travesía" debe re-marcarse a "TripSquad" (tarea en TASKS).
- El nombre coincide con el repo (`TripSquad-iOS`), reduciendo fricción.
- Si en el futuro se quiere cambiar, NO se edita este ADR: se escribe un ADR-00XX que lo
  reemplace (supersede).
