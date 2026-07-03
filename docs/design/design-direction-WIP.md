# Diseño — dirección (WIP, SUPERSEDED)

> **SUPERSEDED 2026-07-03 por `DESIGN.md` + ADR-0003.** Queda como registro histórico del proceso.
> La dirección final NO es la de este archivo (vidrio/aurora con gradientes): tras iterar y hacer
> investigación anti-IA, Andrea eligió **editorial minimal cálido** (foto + serif + aire, sin
> gradientes ni cajas iguales). Ver `DESIGN.md`.

Estado: **superseded** (histórico).

## Norte memorable (decidido)
**"Se siente premium, no una hoja de cálculo."** Cada decisión se pregunta: ¿se siente caro y
cuidado, o improvisado? Premium = restricción, precisión, aire generoso, tipografía refinada,
movimiento cuidado. NO color a gritos.

## Tesis de diseño (el hallazgo)
TripSquad vive en **dos registros a la vez**: las zonas sociales/de viaje (hero, countdown,
fotos, itinerario) quieren calidez y energía; las de dinero (gastos, balances, liquidación)
quieren calma, claridad y confianza (fintech). La regla: **base neutra premium constante; la
calidez/color se la gana cada momento emocional; el dinero se queda en calma.** Probable razón
de que "nada convenciera" antes: intentar un solo vibe para toda la app.

## Sistema propuesto (v0 — sujeto a cambio)
- **Estética:** refinado con calidez ("premium travel").
- **Color (restringido):** Tinta (casi-negro cálido) + Papel (blanco roto cálido). Acento de
  firma: **ámbar atardecer**. Verde profundo calmado, semántico, solo en zona de dinero.
- **Tipografía:** Display/Hero = **Fraunces** (serif con alma, diferenciador clave vs.
  competidores que usan sans). Cuerpo/UI = **General Sans**. Dinero = General Sans tabular +
  cifras protagonistas en **Geist Mono** (precisión fintech).
- **Layout:** híbrido; bento disciplinado; hero como póster (foto a sangre).
- **Espaciado:** rejilla 8pt (iOS), densidad cómoda-amplia.
- **Movimiento:** intencional, físico, nativo iOS.

### Seguro vs riesgo
- Seguro: bento de tarjetas, foto grande de destino, rejilla 8pt + motion iOS.
- Riesgos: (1) fuera del azul genérico de viaje → ámbar/verde; (2) serif de display (Fraunces);
  (3) números mono en el dinero.

## Punto de retorno exacto
Andrea pidió ver **"riesgos más salvajes"** antes de generar mockups. Siguiente paso al
retomar: proponer 2-3 direcciones más atrevidas (sobre el mismo norte premium), elegir UNA,
generar 3 mockups con el binario `design`, comparar, decidir → escribir `DESIGN.md` + ADR-0002.

## Investigación de categoría (resumen)
- Bento es patrón mobile 2026 dominante (vamos con la corriente).
- La división planear/dinero se rompe (Wanderlog, Stippl) → el todo-en-uno está validado.
- Vuelve la calidez (grano, textura, formas imperfectas) vs. saturación de visual-IA.
- Dinero pide calma y confianza, no espectáculo. Azul = color por defecto del viaje (Booking,
  Skyscanner) → oportunidad de diferenciar saliéndonos.
