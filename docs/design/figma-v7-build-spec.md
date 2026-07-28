# Figma Build Spec — TripSquad (dirección "card dashboard")

**Tipo:** reference / log de continuidad. **Rige:** `docs/front-constitution.md` (obligatoria) +
`DESIGN.md`. Este doc traduce las decisiones a valores construibles en Figma y guarda los IDs.

> ⚠️ **Disco externo inestable (2026-07-28):** archivos nuevos en `/Volumes/DiscoAndrea/...`
> desaparecieron una vez (este doc + `design/ia-inicio/`). Backups de las imágenes en el
> scratchpad de la sesión y en la nube de Higgsfield. Considerar mover el repo a disco interno.

## Archivo Figma
- Proyecto `appas` · archivo **`yaltk4i23jhWypC7EFgVJj`** · página `TripSquad · v7` (`0:1`).
- Frame iPhone **402 × 874** (iPhone 17 Pro). Gap 40 → siguiente x += 442.
- Fuentes: **Inter** como *proxy* de SF Pro (SF Pro no exporta en Figma) + **Geist Mono** (cifras).

## ⭐ Dirección APROBADA (2026-07-28) — "card dashboard limpio"
Norte visual: `design/ia-inicio/tarjetas-gpt-verde.png` (generada con GPT Image 2 vía Higgsfield).
Blanco/crema · **tarjetas blancas redondeadas** · **número grande** (bote €1.240, `debes €80` verde)
· **tarjeta de gráfica de barras** (una barra en degradado verde) · **tarjeta Movimientos** con
**emoji 3D** por categoría · **tab bar pastilla oscura** (activo verde) · casi sin color, verde en
micro-dosis. SIN foto dominante, SIN countdown, SIN Brújula al centro (retirados por Andrea).
Supersede el v7 lavanda y el piloto verde de hero oscuro. Formalizar con ADR.

## Tokens (colección `VariableCollectionId:4:2`, modo Light `4:0`)
Neutros: crema `4:3` #F5F1E9 · blanco `4:4` #FFFFFF · papel-recibo `4:5` #FBF7EF · tinta `4:6`
#241F1A · piedra `4:7` #8C8375 · hairline `4:15` #241F1A@8% · glass-borde `4:16` #FFFFFF@60%.
Verde (marca/acento): profundo `13:2` #0E4835 · noche `13:3` #072A20 · **medio `13:4` #1E6F52
(ACENTO)** · bruma `13:5` #E8EEE9.
UI card dashboard: **oscuro/tabbar `27:2` #17181A** · **chart/barra `27:3` #E8E6E1**.
Especiales (dosis mínima): bronce-sello `4:10` #C9A876 · burdeos-compra `4:9` #6E1423 · terracota
`4:12` #C98A6B (deuda/negativo). Retirados del uso: lavanda `4:8`, salvia `4:11`, ámbar `4:13`,
agua `4:14`.

## Estilos de texto (10)
Hero/Ciudad, Hero/Apellido, Titulo/Seccion, Cuerpo/Base, Cuerpo/Medium, Label/Overline, Caption
(Inter, proxy SF Pro) + Dato/Countdown, Dato/DineroL, Dato/MonoS (Geist Mono).

## Nodos construidos
- **Tablero de sistema** `00 · Sistema v7` (`6:2`): Color + Tipografía + demo Liquid Glass.
  (La sección Color muestra la paleta; refrescarla a la dirección card-dashboard si hace falta.)
- **✅ Pantalla aprobada:** `Inicio · card dashboard` (`28:2`), content `28:3`, tab bar `32:2`.
  Cabecera + bote €1.240 (debes verde) + pastillas + squad (Marta·Leo·Nora·Bruno·Vera) + card
  gráfica (barra Aloj verde) + card Movimientos (emoji 🍴🛏️🚋) + tab bar oscura (Viaje verde).
  Movimientos queda bajo el fold (scroll real).
- **Obsoleto:** piloto verde hero oscuro `Gastos · piloto verde` (`14:2`).

## Pendiente
Pulido chart (más alto, etiquetas por categoría/día), y construir las demás pantallas (Gastos,
Planes, Chat, Inicio-lista de viajes…) en este estilo, siguiendo `front-constitution.md`
(fases + skills de taste + agente-usuario + testeo).
