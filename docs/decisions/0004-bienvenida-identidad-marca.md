# ADR-0004 — Bienvenida: identidad A+C, escenas funcionales y carrusel

- **Fecha:** 2026-07-09
- **Estado:** accepted
- **Dueña:** Andrea

## Contexto
La UI base está bloqueada en v6 (vidrio premium oscuro, DESIGN.md), pero el onboarding "no
gustaba" porque faltaba la identidad de marca. Se exploró un moodboard emocional
("nosotros/juntos") que derivó en la dirección **A+C**: criaturas translúcidas que brillan
por dentro (aerografiado, ojitos de luz, cada amigo un tono) sobre noche. Andrea validó la
dirección para **marca (logo + bienvenida)** y añadió el brief clave: *la imagen y la frase
deben explicar lo que puedes hacer con la app y qué te ahorra; las criaturas deben ayudar a
contarlo, con roles distintos, no ser clones*.

## Decisión
La bienvenida de TripSquad es un **carrusel de 5 escenas funcionales** donde las criaturas
del squad HACEN lo que la app hace, cada una con titular simple:

1. **Planead juntos.** — la mesa con el mapa (hub/planificación)
2. **Gastos sin líos.** — el reparto de orbes en partes iguales (gastos/liquidación)
3. **Votad y listo.** — la elección playa/monte con manitas arriba (votaciones)
4. **Nadie se pierde.** — la fila con brújula por la ruta que brilla (itinerario/Brújula IA)
5. **Las fotos, juntas.** — los recuerdos flotantes (fotos)

Tipografía y composición (firmado 2026-07-09 tras auditoría UX): titulares en **redonda
bold centrada** (SF Rounded / `ui-rounded`; en SwiftUI `.rounded`) — habla el idioma
blandito de las criaturas; todo el eje de la pantalla centrado (marca, titular, criaturas,
dots, botón). Se descartó la serif itálica alineada a la izquierda (rompía el eje y chocaba
con el mundo del personaje). Botones a mínimo táctil de 44 pt.

Flujo: pantallas 1–4 con botón único **«Siguiente»** (pill compacta); la 5ª cierra con
**«Continuar con Apple»** + **«Continuar con Google»** + enlace «¿Ya tienes cuenta? Inicia
sesión», y el subtítulo del bento ("Chat, planes, gastos, votos y fotos — todo el viaje en
un sitio").

Animación: **loops 2.5D con DepthFlow** (open source, github.com/BrokenSource/DepthFlow):
vaivén de cámara + profundidad que respira, ciclo de 6s que cierra perfecto. En la app se
reproduce como asset en bucle (o se recrea el efecto en SwiftUI por capas); respeta
"Reducir movimiento".

Ámbito: esta calidez (gradiente iridiscente, criaturas glow) es **la marca — logo y
bienvenida**. NO reabre la estética base de la app, que sigue siendo v6 vidrio (DESIGN.md).

## Alternativas consideradas
- **Titulares emocionales** ("Mientras haya un nosotros, basta") — bonitos pero no explican
  el producto; rechazados por Andrea a favor de valor simple y directo.
- **Hero único (una sola pantalla)** — mínimo, pero solo enseña un beneficio.
- **Collage todo-en-uno** — todo el valor en un frame, pero ruidoso y sin aire para titular.
- **Vídeo IA (Veo/Kling/Higgsfield)** — gestos reales de las criaturas, pero de pago/sin
  acceso y sin loop garantizado. Wan/LTX local descartado por lentitud en la máquina (M4
  Air, 16 GB). DepthFlow gana: gratis, 1s de render por clip, loop matemático.
- **Estilo plano/vectorial para las criaturas** — ya rechazado (R2-2): el acabado firmado es
  translúcido-glow, nunca plano.

## Consecuencias
- La bienvenida queda **cerrada para diseño**: escenas, copy, flujo y animación firmados.
  El tablero vivo: https://claude.ai/code/artifact/2bbcfe9a-792c-4a63-ba25-d9b1f313fb24
- Assets (stills + loops + prompts + script de animación) versionados en
  `docs/design/bienvenida/`.
- El **logo** sigue pendiente de pick (candidato recomendado: 3 criaturas glow sobre
  casi-negro); irá en ADR propio.
- Las imágenes actuales son dirección firmada generada con IA (Gemini 3 Pro); si se rehacen
  en alta calidad final (ilustración propia o regeneración), deben pasar el filtro
  "translúcido-glow, sin bocas, roles distintos".
- Cuando arranque el código: pantallas SwiftUI del carrusel según este ADR; "Continuar con
  Apple" es obligatorio al ofrecer Google (regla de App Store).
