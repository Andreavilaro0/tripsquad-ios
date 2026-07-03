# CONTEXT — TripSquad

Estado vivo del proyecto. Actualizar al cerrar cada sesión.

## Qué es
App iOS para grupos de amigos que viajan juntos. Bento: chat, itinerario, gastos +
liquidación, votaciones, fotos, Brújula IA (premium). Valor = integración (el bento).

## Fase actual
**Pre-código, design-first.** Código anterior borrado a propósito (bucle de rediseñar en
mitad de código). Orden de trabajo: sistema operativo (hecho) → diseño visual (✅ CERRADO,
ver DESIGN.md + ADR-0003) → alcance MVP (SIGUIENTE) → arquitectura → código.

## Dónde estamos (2026-07-03)
- ✅ Sistema operativo del proyecto definido (método, arsenal, gobierno de agentes, memoria,
  decisiones-ADR, documentación). Design doc aprobado:
  `~/.gstack/projects/docs/andreaavila-no-git-design-20260630-153734.md`.
- ✅ Marca decidida: **TripSquad** (ADR-0001).
- ✅ Base del repo montada: git (main), CLAUDE.md, constitution.md, docs/decisions, etc.
- ✅ **Diseño visual CERRADO (2026-07-03)** (`/design-consultation`). Dirección: **editorial
  minimal cálido** (foto art-dirigida a sangre + serif Fraunces + aire; paleta papel/tinta/óxido;
  doble registro social/dinero). Fuente de verdad: **`DESIGN.md`**. Decisión: **ADR-0003**. Validada
  contra la app real Retro. Previews + investigación anti-slop en
  `~/.gstack/projects/TripSquad-iOS/designs/design-system-20260702/`.

## Producto (spec heredado — re-marcar de "Travesía" a "TripSquad")
- `docs/travesia-product-overview.md` — el qué/por qué de cada pantalla.
- `docs/travesia-navigation-map.html` — inventario de vistas + estado de implementación previo.
  (Stack previo: SwiftUI + Supabase + Clean Architecture. Útil como referencia, no como verdad.)

## Decisiones clave
Ver `docs/decisions/`. ADR-0001 = marca TripSquad.

## Riesgo a vigilar
Sobre-construir el sistema/herramientas en vez de avanzar el producto. El diseño es el
siguiente paso real y el mayor dolor histórico de Andrea.
