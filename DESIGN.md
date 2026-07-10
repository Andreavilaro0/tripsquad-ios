# DESIGN.md — TripSquad

Fuente de verdad del diseño. **Léelo SIEMPRE antes de cualquier decisión visual o de UI.**

Estado: **v7 — SOBRIEDAD BLANCA + Liquid Glass claro. APROBADA por Andrea 2026-07-09** ("bueno
voy a suponer que se verá mejor en el simulador así que sí, apruebo"). Prototipo interactivo de
referencia: https://claude.ai/code/artifact/5e412cec-aaef-4c16-ba35-a0a5edb82e58 — el v6 oscuro
cinemático queda como candidato a modo noche (historial v4 del artifact).
**F0 firmada 2026-07-10 por delegación de Andrea** ("te dejo a ti todas las decisiones") —
acento, componentes, efectos, logo y checklist abajo; ADR-0006. Plan de fases:
`~/.gstack/projects/TripSquad-iOS/andreaavila-main-design-20260710-fases-cierre-uxui.md`.

## Frontera de lo FIRMADO (P2 — no se reabre sin ADR nuevo)
FIRMADO: clave clara v7 (reglas 1–7), tokens de color base, receta glass, tipografía,
radios/sombras/espaciado, doble registro, bienvenida (ADR-0004), monetización híbrida,
acento (abajo), efectos firma (abajo), componentes F0 (abajo).
ABIERTO (se firma en su fase): microcopy paywall (F2) · componentes de mapa y mapa base (F3a) ·
modo noche (F4) · sustitución de fotos placeholder (F5).

## Norte memorable
**Fluido y premium — "un agente de viajes que lo resuelve".** Una solución, no otra herramienta. Se siente **premium, no una hoja de cálculo.** Vidrio limpio, movimiento fluido, foto cinematográfica. Paleta cálida **que no cansa**.

## ⭐ LA CLAVE CLARA (v7) — reglas aprobadas

1. **Papel y bruma.** Fondo crema `#F5F1E9`. La foto cinemática NUNCA se corta: se **funde en
   bruma** hacia el papel (gradiente foto→crema, patrón ref Onda). El título pasa a tinta
   sobre el papel.
2. **Vidrio claro SOLO en controles** (chips, countdown, sheet, tab bar, botones flotantes).
   Receta de maqueta (en SwiftUI real es `.glassEffect`): `fondo blanco 34–36% + blur 16–24 +
   saturación 150–180% + borde blanco 60% + LUZ ESPECULAR arriba (inset 0 1px 0 blanco 70%)`.
   Sin esa línea de luz, el vidrio parece niebla.
3. **Contenido = tinte sólido** (blanco 78–100%, hairline blanca, sombra tímida). Nunca vidrio
   sobre vidrio.
4. **Sans ligera dentro de la app** (SF Pro 300–600; título de viaje en 300–350). NADA de serif
   en la app — serif/redonda viven en marca y bienvenida (ADR-0004). Mono solo cifras/metadatos.
5. **Acento en micro-dosis, exactamente 4 sitios:** puntito de estado en chips, check al
   votar/completar, cifra de deuda («debes €80»), punto de tab activa. El acento JAMÁS rellena
   botones ni fondos; el CTA es tinta o blanco.
6. **Casi monocromo.** Avatares y neutros en tonos piedra. El color lo ponen la foto y las 4
   gotas de acento.
7. **Título doble sobrio:** ciudad grande + apellido gris («Lisboa / Viaje con el squad») +
   countdown en 3 celdas de vidrio (DÍAS·HRS·MIN, cifras mono).

---

## ⭐ REGLAS PRIORITARIAS — Liquid Glass (Apple) — NO NEGOCIABLES

Basadas en la doc oficial de Apple + WWDC25 "Meet Liquid Glass". En iOS 26 el material es **nativo** (`.glassEffect` en SwiftUI): diseñar así = premium y nativo gratis.

1. **El vidrio es SOLO la capa de navegación/controles** que flota sobre el contenido: tab bar, toolbars, botones, sheets, pills. **NUNCA sobre el contenido** (listas, fotos, media). El contenido manda; el vidrio es capa funcional encima.
2. **Dos variantes, NUNCA mezcladas:**
   - **Regular** — adaptativa y legible. Para casi todo (sheet, tab bar, toolbars).
   - **Clear** — siempre transparente, **requiere capa de oscurecido (scrim)**. Solo sobre media brillante (p. ej. pills sobre la foto).
3. **PROHIBIDO vidrio sobre vidrio** (padre + hijo con glass = redundante y pesado en GPU). Un módulo dentro de un sheet de vidrio va como **tinte sólido suave**, no como segundo glass.
4. **Reservar el vidrio para componentes estáticos de arriba.** NO usar glass en listas, áreas de scroll frecuente ni vistas anidadas (coste GPU).
5. **Tinte con moderación.** El acento (color de marca) aparece sobre todo en **estados seleccionados y acciones** (tab activa, "votar", "debes €80", CTA). El color principal lo pone la **foto**, no la UI. El tinte se adapta al brillo del fondo para no perder legibilidad.
6. **Cada capa se adapta** a lo que hay detrás (refracción, specular, claro/oscuro). Respetar accesibilidad: **Reduce Transparencia / Reduce Movimiento / Aumentar Contraste** (fallback a más opaco/menos blur).
7. **Legibilidad primero.** Texto siempre sobre fondo con contraste suficiente (scrim/blur bajo el texto sobre foto). Radios de esquina **concéntricos** (anidan).

Referencia web (solo para landing/prototipo, NO para la app nativa): liquidGL (naughtyduk, WebGL, MIT). La app real usa el material nativo de iOS.

## ⭐ REGLAS EDITORIALES — anti-"hecho con IA" — PRIORITARIAS

Aprendidas de Andrea (12 sites con builders de IA, todos con la misma vibra: hero centrado, botones de degradado, iconos lucide, glow débil — detectable en 3 s). Lo que lo arregla:

1. **Paleta de ~7 colores con 1 acento INUSUAL** (mostaza, rosa polvorienta, terracota…), NO el default de 3 colores tipo Tailwind. El acento predecible mata la personalidad; el inusual la crea.
2. **NADA de `rounded-2xl` en todo.** Radios pequeños (`rounded-md`, ~6–8 px) o **sin radio** en el contenido (fotos, tarjetas, módulos). Excepción: las **cápsulas de Liquid Glass** (tab bar, pills) son cápsula por diseño de Apple — eso se queda.
3. **1 sans + 1 serif, NO 2 sans.** Emparejar una serif de carácter con una sans limpia. (Mono solo para cifras, uso funcional.)
4. **Componerlo como una REVISTA, no como landing de SaaS.** Asimétrico, espaciado editorial, jerarquía tipográfica fuerte. Nada de "todo centrado".

Estas reglas conviven con Liquid Glass: **el vidrio es el material de la capa de controles; el arte editorial (tipo, ritmo, asimetría, color) va en el contenido.**

---

## Doble registro (tesis)
Base neutra cálida constante. **Social/viaje** (hero, fotos, itinerario) = calidez, foto, energía. **Dinero** (gastos, liquidación) = calma, cifras en mono, sin espectáculo. La calidez se la gana cada momento emocional; el dinero se queda tranquilo (ver recibo real en Gastos).

## Tokens (v7 — clave clara)

### Color
| Rol | Hex | Uso |
|---|---|---|
| Crema | `#F5F1E9` | Fondo base de la app |
| Blanco | `#FFFFFF` | Tarjetas de contenido (tinte sólido 78–100%) |
| Papel recibo | `#FBF7EF` | Módulo dinero (recibo) |
| Tinta | `#241F1A` | Texto principal |
| Piedra | `#8C8375` | Texto secundario, metadatos, iconos inactivos |
| Hairline | `#241F1A14` | Líneas finas sobre claro |
| Glass borde | `#FFFFFF99` | Borde especular del vidrio claro |
| **Acento** | **Lavanda `#9782B8`** | **FIRMADO F0.** Micro-dosis, exactamente los 4 sitios de la regla 5 |
| Compra | `#6E1423` Burdeos | EXCLUSIVO del momento de compra (paywall CTA); jamás en otra UI |
| Bronce sello | `#C9A876` | Solo sellos de viaje y marca; los dorados SIEMPRE sobre tinta (contraste) |

**Acento FIRMADO (F0, 2026-07-10): Lavanda `#9782B8`** — viene de la ref crema favorita de
Andrea, lleva 3 versiones como default del prototipo sin objeción, y es el acento "inusual"
que piden las reglas editoriales. Los demás candidatos quedan descartados; la paleta funcional
apagada (lavanda/salvia/terracota/ámbar/agua) sigue viva SOLO para contenido social
(categorías de gasto, pines, etiquetas de día), nunca como acento de UI.

**Paleta funcional (contenido social):** lavanda `#9782B8` · salvia `#7FA08C` · terracota
`#C98A6B` · ámbar `#D8B24A` · agua `#9FB6BF`.

**Modo noche (candidato, no firmado):** el v6 oscuro cinemático (night `#141110`, foto
desaturada + scrim, mismos micro-acentos) — historial v4 del prototipo.

### Tipografía
En la app: **SF Pro / sans del sistema, pesos 300–600** — sans ligera, sobria (título de viaje
en 300–350). **Sin serif dentro de la app** (decisión 2026-07-09; la serif editorial fue
descartada por chocar con la sobriedad). Cifras/dinero/datos: **SF Mono / Geist Mono**
(tabular). La redonda (SF Rounded) y las criaturas viven SOLO en marca/bienvenida (ADR-0004).

### Layout / motion
Rejilla ~8pt. Radios jerárquicos y concéntricos. Movimiento fluido, físico, nativo iOS (el norte es "fluido"). Detalles-con-vida aprobados: **recibo térmico real** (Gastos), **brújula de vidrio** + **countdown expresivo** + **módulo de clima** (Hub). Descartado: page-curl.

## Componentes FIRMADOS (F0, 2026-07-10 — galería: https://claude.ai/code/artifact/7d4b02f9-6118-475c-9b08-052a86fca5cc)

**Entran a v1** (con su módulo y esfuerzo):
1. **Sello holográfico de viaje** (Fotos/cierre; shader foil tipo Sticker; el efecto-firma de la marca) — S
2. **Split-flap countdown** (Inicio·Póster D2; lento, en tinta) — S
3. **Mapa espina-dorsal** (Planes; ruta que se dibuja por día; rutas REALES vía MKDirections, nunca rectas) — M
4. **Fly-to + pin→tarjeta** (mapa fullscreen; MapCameraPosition animado + Annotation SwiftUI) — S/M
5. **Pin sonar** (mapa; algo nuevo aquí — gasto/foto) — S
6. **Arcos del squad convergiendo** (póster pre-viaje/countdown; MKGeodesicPolyline) — S
7. **Avatares squad en mapa + glow "juntos"** (durante el viaje; SIEMPRE opt-in por viaje, lenguaje Find My) — M
8. **Donut de gastos tocable** (SwiftUICharts) + **simplificar deudas** + **liquidar con confetti** — S/M
9. **Votaciones mazo swipe + squish** — M
10. **Text Blast del organizador** (avisos fuera del chat) — S
11. **Brújula viva:** shimmer al pensar + ripple al preguntar + prompt gooey — S
12. **Tab bar squash & stretch** (pastilla con física) — S
13. **Botones squishy** (spring 0.2/0.4 en checks/reacciones) — S
14. **Live Activity "día de viaje"** (Dynamic Island; patrón Flighty) — M (se diseña la tarjeta en F3a, va al spec)
15. **Recap compartible al cerrar viaje** (fotos+mapa+gastos+sello) — M (F3b, flujo de cierre)
16. **Transición bienvenida→app** estilo ConcentricOnboarding — S (F4)

**Aplazados a v1.1+ (explícito, no muertos):** globo de puntos (crear viaje), scrubbing de ruta
con gradiente, compare-slider presupuesto/gastado, text explode en chat, widget squad, paleta
dinámica por destino (Tide Guide).

**Dependencias SwiftUI aprobadas** (MIT, activas): ConfettiSwiftUI · SwiftUI-Shimmer ·
willdale/SwiftUICharts · ClusterMap (si hay clustering). **Pow NO** (licencia de pago).
Chat: evaluar SwiftyChat para Brújula en F2 (decisión técnica, no de diseño).

## Efectos firma + accesibilidad (F0 — reglas duras)
- Sello lacre bronce circular (coleccionable, 1 por viaje) · springs iOS (0.2/0.4 juguetón ·
  0.3/0.8 momentum · 0.4/1.0 sólido) · tilt de fotos ±5° · grain ≤12% · borde-glow SOLO
  celebraciones · **confetti SOLO en hitos: pago completado, liquidación cerrada, cierre de
  viaje. Nada más.**
- **Reduce Motion:** todo efecto tiene versión estática definida (sello→foil fijo, split-flap→
  cifra sin volteo, confetti→badge ✓, parallax bienvenida→still).
- **Contraste AA:** dorados/bronce solo sobre tinta (medido: fallan sobre claro); burdeos sobre
  crema = 10.4:1 ✓; lavanda como acento de texto solo en cifras grandes (≥17pt).

## Logo (F0)
**Isotipo base FIRMADO: R3-logo3** (criatura glow, candidato recomendado desde la exploración
de identidad). Refinamiento bespoke (trazo, versiones app-icon) = tarea de marca post-F5,
NO bloquea fases. La marca vive en bienvenida; dentro de la app no hay logo flotante.

## Checklist de huecos (F0 — el alcance es esto, 20 wireframes)
00: TOKENS V7 · LOGO·ISOTIPO · SELLO DE VIAJE · ICONOGRAFÍA — 01: (bienvenida ✓ hecha) ·
TRANSICIÓN→APP — 02: INICIO·SIN VIAJES · INICIO·PASADOS (+ D2 un-viaje y D3 varios ya en
dirección) — 03: CREAR·2 VÍAS · CREAR A MANO · BRÚJULA·AGENTE · PAYWALL · BRÚJULA BLOQUEADA —
04: MAPA COMPLETO · VOTACIÓN·DETALLE · LIQUIDAR·FLUJO (+ Hub/Planes/Gastos/Chat/Fotos ya en
dirección v7, se afinan en F3) — 05: INVITAR AL SQUAD · PERFIL · NOTIFICACIONES · AJUSTES DEL
VIAJE · AJUSTES APP. La tarjeta "Día X" vive dentro de Hub/Planes (no es hueco propio).
"Relleno" = flujo completo + estados clave en v7 final, no boceto.

## Anti-slop
Ver `~/.gstack/projects/TripSquad-iOS/designs/design-system-20260702/referencia-anti-slop.md` (clichés IA a evitar + apps reales de referencia: BIORG, Onda, Invoice, Flighty, Glass).

## Registro de decisiones
| Fecha | Decisión | Fuente |
|---|---|---|
| 2026-07-03 | Base v6 (vidrio premium) bloqueada; reglas Liquid Glass de Apple como prioritarias | Andrea + doc Apple/WWDC25 |
| 2026-07-03 | Acento amarillo/ámbar descartado ("cansa"); paleta en evaluación | Andrea + investigación color |
| 2026-07-09 | Bienvenida cerrada: carrusel 5 escenas criaturas + redonda centrada + Siguiente/Apple/Google (ADR-0004) | Andrea |
| 2026-07-09 | **v7 aprobada: sobriedad blanca + Liquid Glass claro** (papel+bruma, sans ligera, acento micro 4 sitios); serif fuera de la app; v6 oscuro pasa a candidato de modo noche (ADR-0005) | Andrea |
| 2026-07-10 | Plan de fases F0–F5 aprobado (vía "el río" + hilo Lisboa; fecha objetivo 31-07) | Andrea |
| 2026-07-10 | **F0 firmada por delegación** ("te dejo a ti todas las decisiones"): acento Lavanda `#9782B8` · 16 componentes v1 + 6 aplazados · efectos firma con Reduce Motion/AA · logo R3-logo3 · .pen al repo (pendiente Cmd+S de Andrea) · checklist 20 huecos (ADR-0006) | Andrea→Claude |
| 2026-07-10 | **F4 · Soporte cerrada** (delegación): transición bienvenida→app concéntrica (círculo papel, 0.4/1.0, Reduce Motion=fundido) · invitar (link sin cuenta obligatoria, pendientes con reenviar) · perfil (vitrina de sellos) · avisos (dot de color por tipo, agrupados por viaje) · ajustes viaje (ubicación opt-in, salir no borra gastos) · ajustes app. **◆ MODO NOCHE: APLAZADO a v1.1** (fila "PRONTO"; la sobriedad blanca es la identidad v1; Hub v6 oscuro sigue archivado) | Andrea→Claude |
| 2026-07-10 | **F3a+F3b · Dentro del viaje cerradas** (delegación): mapa fullscreen fly-to (papel crema, pines-foto con anillo por día, ruta lavanda, chips DÍA glass, badge "✨ MA+LE aquí", sonar "+€12", pin→tarjeta glass) · tarjeta Día X = Live Activity Flighty (isla expandida + lock card + reglas) · Votación mazo swipe (sello SÍ salvia / NO burdeos, botones ✕/✓, parciales con barra lavanda) · Liquidar (simplify 7→2 pagos) → Cuentas en paz (sello + confetti hito) → recap compartible → "Cerrar viaje — pasa a tus recuerdos" · Text Blast en Chat (lavanda, visto 5/6, fijado). **◆ mapa base: MapKit nativo v1** (fluidez > estilo custom; MapLibre solo si el simulador "grita genérico" — lado a lado → ADR-0007) | Andrea→Claude |
| 2026-07-10 | **F2 · Crear+Brújula+Paywall cerrada** (delegación): sheet 2 vías (Brújula 1ER GRATIS / a mano gratis siempre) · form manual con squad+portada · Brújula agente (bubbles, cards añadir, quick-replies, PENSANDO=shimmer, ERROR IA="culpa nuestra, salida clara") · Paywall burdeos: "Este viaje 4,99 € · una vez, todo el squad" vs "Pro 2,50 €/mes cobrado 29,99 €/año", escape SIEMPRE visible "o hazlo a mano — gratis siempre" · Bloqueada: "Brújula descansa", chips muertos, prompt muerto. Microcopy firmado: honesto, sin countdowns falsos ni culpa | Andrea→Claude |
| 2026-07-10 | **F1 · Inicio cerrada** (delegación): Inicio se adapta al nº de viajes — sin-viajes (hero Brújula con prompt + crear-a-mano + populares) / un-viaje (Póster D2, ahora con countdown SPLIT-FLAP) / varios (Bento D3, Brújula como tile ◆) / pasados (bandas con SELLOS bronce ◆ + segmento Próximos·Pasados). Estados: shimmer esqueleto, error con salida, offline como banner (no pantalla). Hilo Lisboa jun 2026 en todo | Andrea→Claude |
