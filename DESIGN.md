# DESIGN.md — TripSquad

Fuente de verdad del diseño. **Léelo SIEMPRE antes de cualquier decisión visual o de UI.**
Ninguna pantalla se codifica sin respetar este sistema. Para cambiarlo, no se edita a la ligera:
se registra un ADR nuevo que reemplace al ADR-0003.

Estado: **v1 (dirección aprobada 2026-07-03, ADR-0003).** Decidido por Andrea.

---

## Norte memorable
**"Se siente premium, no una hoja de cálculo."** Y más concreto: **fluido y premium — como un
agente de viajes que lo resuelve.** Una solución, no otra herramienta. Cada decisión se pregunta:
¿esto se siente caro, cuidado y hecho por alguien con criterio, o generado/improvisado?

## Tesis: doble registro
TripSquad vive en dos registros a la vez sobre una **base neutra cálida constante**:
- **Social / viaje** (hero, countdown, fotos, itinerario): calidez y energía. La foto pone el color.
- **Dinero** (gastos, balances, liquidación): calma, claridad, confianza. Papel, cifras en mono,
  cero color. El dinero **no** es espectáculo.

Regla: la calidez/foto se la gana cada momento emocional; el dinero se queda en calma.

## Estética
Editorial minimal cálido. Tipografía + fotografía + aire hacen el trabajo. Referencia real que
valida la dirección: **Retro** (serif enorme + foto cálida candid + blanco radical). Otras a minar:
Partiful, Airbnb, Flighty, Glass, Geneva, Lapse (ver `~/.gstack/projects/TripSquad-iOS/designs/
design-system-20260702/referencia-anti-slop.md`).

---

## Color — 3 colores y punto
El color se gana; no se reparte. Acento **solo en gotas** (acción, dato clave, sección).

| Rol | Hex | Uso |
|---|---|---|
| Papel | `#F7F2EA` | Fondo base (modo claro) |
| Papel-2 | `#ECE4D7` | Superficies sutiles, citas |
| Hairline | `#DED4C4` | Líneas finas, divisores |
| Tinta | `#1A1714` | Texto principal (casi-negro cálido) |
| Tinta-soft | `#867C6E` | Texto secundario, metadatos |
| Óxido (acento) | `#C06A22` | ÚNICO acento. Acción, dato clave, punto de sección |
| Noche | `#161311` | Fondo base (modo oscuro) |
| Noche-texto | `#F2ECE4` | Texto sobre oscuro |
| Noche-hairline | `rgba(255,255,255,.10)` | Divisores en oscuro |

- **Prohibido:** morado/violeta eléctrico, gradientes decorativos (violeta→azul, teal→morado,
  neón), azul "SaaS/viaje" por defecto, blobs borrosos de fondo, paletas saturadas.
- **Dinero:** las cifras van en tinta + mono; el verde/semántico NO se usa como color de marca.
  El óxido solo aparece en la acción (p. ej. "debes €80", "pagar", "votar").
- El color de las fotos se integra en la sensación, no se inventan colores de UI.

## Tipografía
| Rol | Fuente | Notas |
|---|---|---|
| Display / Hero | **Fraunces** (~peso 400, opsz alto) | Serif con carácter y contraste. El protagonista. |
| Cuerpo / UI | **General Sans** | Legible, cálida, neutra-premium |
| Cifras / dinero / datos | **Geist Mono** (tabular) | Precisión = confianza |

- **Prohibido como display o cuerpo:** Inter, Roboto, Poppins, Montserrat, Open Sans, Lato,
  Space Grotesk, y `system-ui`/`-apple-system` como display. (Convergencia = slop.)
- Escala modular con jerarquía real; el hero puede ser MUY grande (montando sobre la foto).

## Layout
- **Editorial, alineado a la izquierda.** Nada de "todo centrado".
- **Jerarquía por frecuencia:** lista + 1 ítem destacado. NO rejilla de cajas iguales (no bento
  de tarjetas idénticas). Si hay grid, 2 columnas máx y texto primero.
- **Foto a sangre** (full-bleed) art-dirigida arriba; el título serif grande puede **montar** sobre
  ella (asimetría, tensión).
- **Firma editorial:** wordmark *Trip**squad***, índice ("N.01 — VIAJE"), numeración de secciones
  (01 HOY / 02 CUENTAS), detalles tipo coordenadas. Estos detalles combaten el look IA.
- **Radio jerárquico** (no 16px en todo): 8–10 px inputs/filas, 12–16 px tarjetas, pill completo
  solo para CTA principal y chips.
- CTA principal en el tercio inferior (alcance del pulgar).
- **Vidrio con moderación:** materialidad afinada, no glassmorphism en cada elemento.

## Fotografía
La base del look. Mix: **destino curado de internet + álbum del squad** (fotos propias, que pueden
venir con mala luz). El sistema debe verse bien con las dos.
- **Grade cálido consistente** (revelado tipo película: sepia sutil, saturación baja, contraste
  alto). Integra el color de la foto en la UI.
- Preferir escenas reales (destinos reales, la peña real), no fondos abstractos ni stock genérico.
- Grano/textura sutil en superficies para materialidad (no superficies planas estériles).

## Voz (microcopy)
Cálida, concisa, "de squad", nunca corporativa ni de marketing. Concreta, no placeholder.
- Bien: "Ana ya reservó el Airbnb", "faltan 12 días", "4 votos, empate".
- Mal: "Bienvenido a tu viaje", "Explora experiencias increíbles".
- Escribir estados vacíos, error y onboarding con esta voz. Emoji con cuentagotas.
- La **Brújula IA** habla con voz propia (cita, sugerencia útil), no es un botón genérico.

## Movimiento
Intencional, físico, nativo iOS. Microinteracciones con peso (press, lift, parallax al hacer
scroll). Easing con curvas/spring, no el easing genérico por defecto. Transiciones que apoyan la
narrativa. Respetar safe areas, Dynamic Island y home indicator reales (nada de status bar falso).

---

## Anti-slop (resumen)
Tabla completa "IA suele decir X → reformúlalo a Y" en
`~/.gstack/projects/TripSquad-iOS/designs/design-system-20260702/referencia-anti-slop.md`.
Regla de oro: **IA para explorar, humano para decidir.** Darle constraints (estos tokens, contenido
real, mood board); no dejar que caiga en defaults.

## Pendiente de diseño REAL (no bloquea, pero separa "preview" de "producto")
1. **Fotografía** curada/propia con dirección de arte consistente (lo #1 según la investigación).
2. **Wordmark + iconografía bespoke** (ahora simulados con Fraunces cursiva e iconos de trazo
   genérico). Set propio con mismo grosor/radio que el tipo.

## Previews de referencia
`~/.gstack/projects/TripSquad-iOS/designs/design-system-20260702/`
- `preview-v4-antislop.html` — hub, dirección aprobada.
- `preview-v3-variantes.html` — Gastos/liquidación (G1/G2/G3) + afinados de hub.
- `referencia-anti-slop.md` — clichés IA + apps reales a minar.
- `refs-andrea-20260702/` — referencias originales de Andrea.

## Registro de decisiones
| Fecha | Decisión | Fuente |
|---|---|---|
| 2026-07-03 | Dirección de diseño v1 (editorial minimal cálido) aprobada | ADR-0003 · /design-consultation |
