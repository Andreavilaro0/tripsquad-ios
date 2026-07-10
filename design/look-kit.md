# Kit del Look — liquid glass · luxury · divertido

Síntesis de 3 investigaciones paralelas (2026-07-10): análisis de las 19 refs de Andrea
(`~/Desktop/carpeta sin título 2/`) + recetas web de vidrio claro + diversión-premium.
Tablero visual con demos: https://claude.ai/code/artifact/5b7e95d3-57b8-46e2-a8b0-898c8481970a

## Hallazgo central
El vidrio de las refs de Andrea NO es el glass frío azulado genérico: **tiñe cálido
(crema→terracota)** — "hotel boutique", no "app de banco". Y lo más luxury de la carpeta
no es un color sino un símbolo: **el sello circular bronce tipo lacre**.

## Recetas de vidrio claro (CSS de maqueta; en iOS = .glassEffect + tint)
- **Sutil** (chips, tab bar): blanco 12% · blur 8 · saturate 180% · brightness 1.08 ·
  borde blanco 25% · 1 specular inset arriba.
- **Media** (sheets, countdown): blanco cálido 16% · blur 13 · saturate 170% · doble
  specular (arriba+abajo).
- **Prominente CÁLIDA** (hero, Brújula): degradado crema→terracota 14–20% · blur 18 ·
  saturate 190% · 4 speculars + **sheen animado** (gradiente 135° blanco 40%→transparente,
  mix-blend screen).
Claves: sin `saturate` alto el vidrio claro se ve sucio; blur alto necesita fondo vivo
(foto) detrás; en SwiftUI: `.glassEffect(.regular.tint(...))`, radios `.containerConcentric`.

## Paleta (base firmada + acentos candidatos nuevos)
Firmado: Crema #F5F1E9 · Papel #FBF7EF · Tinta #241F1A · Piedra #8C8375.
Acentos luxury-con-vida NUEVOS (a elegir 1): **Burdeos #6E1423** · **Verde Mayfair
#0A3D2E** · **Cobre #C07A55**. De las refs: **Bronce sello #C9A876** (solo sellos/marca).
Chispa para celebraciones: Party Pink #E8A9C4 · Micro-ámbar #D8B24A. Actual: Lavanda #9782B8.
Dosis: máx 1-2 acentos visibles por pantalla; CTA primario SIEMPRE tinta/blanco.

## Efectos firma
1. **Sello de viaje** (lacre bronce circular, texto en círculo + brújula) — cada viaje
   completado gana el suyo. Coleccionable.
2. **Borde-glow degradado** (halo 2.5px rosa→ámbar→lavanda + blur exterior) — SOLO
   tarjetas de recuerdo/celebración. Es el puente con las criaturas glow de la marca.
3. **Sombra 2 capas**: `0 1px 2px rgba(36,31,26,.06)` + `0 12px 28px rgba(36,31,26,.18)`.
4. **Tilt de álbum** ±5° (nunca 40°); al tocar endereza y escala 1.06.
5. **Grano editorial** 8–12% opacity (más = sucio en claro).
6. **Squircle**: corner smoothing ~60% (radio ≈22% del ancho) en tarjetas/avatares.
7. Tipografía: tabular-nums en dinero; labels uppercase tracking .08–.12em; titulares
   300–400 tracking −.01/−.02em; duotono crema→tinta para unificar fotos dispares.

## Motion (springs iOS: response / dampingFraction)
- Botones/checks/reacciones: **0.2 / 0.4** (juguetón, rebota)
- Sheet al soltar: **0.3 / 0.8** (momentum)
- Navegación/tabs: **0.4 / 1.0** (sólido = caro)
- Default Apple: 0.55 / 0.825 · Confetti: ráfaga 400–600ms, SOLO hitos reales
  (liquidar bote, cerrar itinerario) — la escasez es lo que lo hace premium.

## Reglas que resuelven las tensiones de las refs
R1 Claro dominante (v7); oscuro = modo noche. R2 Foto documental real; ilustración
vectorial NO (lee budget); criaturas = marca, no UI. R3 Saturación a página completa =
marca/bienvenida; en app, color en dosis. R4 Vidrio = controles; contenido plano con
sombra 2 capas. R5 Serif solo logotype/marca. R6 La diversión vive en motion, fotos,
celebraciones y copy — nunca en controles funcionales.

## Pendiente de firma (Andrea)
1. Tinte cálido del vidrio como receta oficial. 2. Acento definitivo. 3. Qué efectos
firma entran al DESIGN.md (sello, borde-glow, tilt, springs, confetti).
