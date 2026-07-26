# Investigación de Competidores (pre-front) — Runbook

> **Referencia de diseño — no es un tracker.** El estado de ejecución y su avance viven en beads (bd), nunca en este documento. Los pasos de abajo son el plan de referencia (viñetas), no checkboxes de seguimiento. Ver AGENTS.md, sección Rules.
>
> _(Runbook de investigación MANUAL — teardown de apps, no código. El "gate" de cada tarea es que su entregable esté completo: captura + las 4 lentes + anti-patrón.)_

**Goal:** Producir un mapa de huecos del FRONT (qué construir, en qué orden, qué es foso vs table stakes vs quick win) comparando 8 competidores con la misma plantilla, en ≤1 semana, para no construir el front a ciegas.

**Architecture:** Teardown sprint. Un "viaje de prueba" idéntico montado en cada app hands-on hace la comparación manzana-con-manzana. Cada competidor se analiza con 4 lentes fijas (patrones / posicionamiento / onboarding / huecos simples) + 1 anti-patrón. La síntesis produce 4 entregables que alimentan el front.

**Tech Stack:** Ninguno (research manual). Herramientas: las 8 apps/fuentes, capturas de pantalla, y un fichero markdown de matriz versionado en git.

## Global Constraints

- Diseño visual CERRADO (2026-07-10). Se investiga FLUJO y MECÁNICA, no estética. No se copia look.
- Timebox DURO: ≤ 1 semana (constitución: "Decidido > perfecto, con fecha"). Si un teardown se estanca, se anota "incompleto" y se sigue; no se rompe el timebox.
- Norte de diseño: "se siente premium, no una hoja de cálculo". Todo patrón candidato a robo se filtra por "¿esto añade claridad o densidad?".
- Sin gasto en apps de pago sin aprobación de Andrea. Usar free tier salvo que un feature Pro sea justo lo que hay que ver; si lo es, anotarlo y preguntar antes de pagar.
- El actor de esta investigación es HUMANO (Andrea). La recopilación de specs/precios/quejas SÍ se puede delegar a un agente; el juicio de flujo ("esto se siente confuso") NO.
- Fuente de verdad del alcance: `~/.gstack/projects/TripSquad-iOS/andreaavila-develop-design-20260725-152729-investigacion-competidores.md` (design doc APPROVED).

## Los 8 competidores

| # | App / fuente | Tipo de dato | Foco |
|---|---|---|---|
| 1 | Wanderlog | hands-on | itinerario + docs + anti-patrón (confuso) |
| 2 | TripIt | hands-on | parseo de PDF/email de vuelos |
| 3 | Splitwise | hands-on | split de gastos + qué NO copiar |
| 4 | Tricount | hands-on | onboarding sin fricción (Europa) |
| 5 | Troupe o Pilot | hands-on (verificar UE) | coordinación de grupo + estado por persona |
| 6 | Mindtrip o Layla (IA-first) | hands-on ligero | benchmark de la Brújula ("planéame 3 días") |
| 7 | Apple Cash bill-split (iOS 27) | **secundario** (specs+vídeos) | la amenaza nativa del recibo-por-foto |
| 8 | Stack informal (WhatsApp+Splitwise+álbum+Doc) | hands-on | el competidor REAL; votaciones = encuesta de WhatsApp |

## Las 4 lentes (idénticas para los 8)

- **L1 — Patrones de UX/flujo:** las 2-3 pantallas/gestos que mejor resuelven su pilar. Captura + una frase de por qué funciona. Marca EL 1 patrón que copiarías tal cual.
- **L2 — Posicionamiento:** ¿qué job hace bien? ¿Dónde el bento integrado de TripSquad le gana (la costura que ellos no tienen)?
- **L3 — Onboarding:** de instalar a "primer valor". Nº de pasos hasta que el grupo está dentro. Dónde se muere la activación. Qué pide antes de dar valor (login/integración/setup).
- **L4 — Huecos simples (quick wins):** la 1-2 cosas PEQUEÑAS y baratas que hace y a TripSquad le faltan (ej: "duplicar día", "moneda auto por país", "editar quién pagó de un tap", "exportar a calendario"). Anota esfuerzo estimado (S/M).
- **Anti-patrón:** la 1 cosa que hace y que TripSquad NO debe hacer.

---

## Task 0: Prework — el guion y el andamio (40 min, ANTES de abrir ninguna app)

**Files:**
- Create: `docs/research/viaje-de-prueba.md` (el guion idéntico)
- Create: `docs/research/competidores-matriz.md` (la matriz vacía)

**Interfaces:**
- Produces: `viaje-de-prueba.md` (el guion que TODA tarea de teardown usa para montar la app) y `competidores-matriz.md` (donde cada tarea escribe su fila).

- **Step 1: Escribe el guion del viaje de prueba**

Crea `docs/research/viaje-de-prueba.md` con EXACTAMENTE esto (rellena los nombres de tu squad real):

```markdown
# Viaje de prueba (guion idéntico para todos los teardowns)

Grupo (4): [tu nombre], [amigo 2], [amigo 3], [amigo 4]
Destino: Lisboa, 3 días (deja fechas fijas: 12-14 sep 2026)
Las 3 tareas que se intentan en CADA app:
1. RESERVA: añadir/seguir un vuelo (reenviar confirmación o meterlo a mano).
2. DECISIÓN: decidir dónde cenar la 1ª noche (proponer 2 sitios y elegir).
3. GASTO: repartir una cena de 80€ pagada por [tu nombre] entre los 4.

Regla: se hace lo MISMO en las 8, para que la matriz compare manzana con manzana.
```

- **Step 2: Verifica disponibilidad de las apps de nicho en la App Store europea**

Abre la App Store (región España) y busca: Troupe, Pilot, Mindtrip, Layla. Anota cuál existe. Si Troupe/Pilot no está, usa la que sí. Si ni Mindtrip ni Layla, usa ChatGPT o Gemini para la tarea IA (#6). Apunta la elección en `viaje-de-prueba.md` bajo un apartado `## Sustituciones`.

- **Step 3: Crea la matriz vacía**

Crea `docs/research/competidores-matriz.md` con una sección por competidor, cada una con este esqueleto (copia el bloque 8 veces, cambiando el nombre):

```markdown
## 1. Wanderlog
- **L1 Patrones:** _(2-3 pantallas + por qué + [ROBAR: ___])_ · captura: `docs/research/img/wanderlog-L1.png`
- **L2 Posicionamiento:** _(qué hace bien / dónde le gana el bento)_
- **L3 Onboarding:** _(nº pasos hasta grupo dentro / dónde muere / qué pide antes de dar valor)_
- **L4 Quick wins que nos faltan:** _(1-2, con esfuerzo S/M)_
- **Anti-patrón:** _(la 1 cosa a NO copiar)_
```

- **Step 4: Crea la carpeta de capturas y guarda**

```bash
cd "/Volumes/DiscoAndrea/Area de trabajo/02-Freelance/apps/TripSquad-iOS"
mkdir -p docs/research/img
git add docs/research/
git commit -m "research(competidores): guion del viaje de prueba + matriz vacia (Task 0)"
```

- **Step 5: Verifica que el andamio está**

Run: `ls docs/research/ docs/research/img/`
Expected: `viaje-de-prueba.md`, `competidores-matriz.md`, y la carpeta `img/`. Abre la matriz y confirma que tiene las 8 secciones con las 4 lentes cada una.

---

## Task 1: Setup — montar el viaje de prueba en las 7 apps hands-on (Día 1)

**Files:**
- Modify: (ninguno — es trabajo dentro de las apps; solo instalas y montas)

**Interfaces:**
- Consumes: `viaje-de-prueba.md`
- Produces: las 7 apps hands-on con el MISMO viaje de Lisboa montado, listas para el teardown. (Apple Cash #7 no se monta: es secundaria.)

- **Step 1: Instala y crea cuenta en las 7 hands-on**

Wanderlog, TripIt, Splitwise, Tricount, la de grupo (Troupe/Pilot), la IA (Mindtrip/Layla/ChatGPT), y ten a mano el stack informal (WhatsApp + Splitwise + Fotos/álbum compartido + un Google Doc). Usa la misma cuenta/email en todas para no perder tiempo.

- **Step 2: Monta el viaje de Lisboa idéntico en cada una**

En cada app: crea el viaje "Lisboa 12-14 sep", invita (o simula) a los 4, e intenta la Tarea 1 (añadir el vuelo). NO hagas las 3 tareas aún — solo deja el viaje creado y el grupo dentro. Aquí es donde vive la fricción de invitación; cronométrala mentalmente, es dato de L3.

- **Step 3: Anota en caliente la fricción de onboarding**

En cada sección de la matriz, rellena YA el L3 (onboarding) mientras lo tienes fresco: cuántos pasos hasta tener el grupo dentro, dónde te frenaste, qué te pidió antes de dejarte hacer nada.

- **Step 4: Guarda el avance de L3**

```bash
git add docs/research/competidores-matriz.md
git commit -m "research(competidores): L3 onboarding de las 7 apps (Task 1, Dia 1)"
```

- **Step 5: Verifica**

Abre `competidores-matriz.md`. Las 7 filas hands-on deben tener el L3 relleno. Si alguna app te bloqueó el onboarding (no pudiste ni crear el viaje), anota "activación murió en: ___" — eso es un hallazgo, no un fallo.

---

## Task 2: Teardown Wanderlog (Día 2) — la que usaste + el anti-patrón

**Files:**
- Modify: `docs/research/competidores-matriz.md` (sección 1)
- Create: `docs/research/img/wanderlog-L1.png` (captura del patrón que robas)

**Interfaces:**
- Consumes: viaje de Lisboa montado en Wanderlog.
- Produces: fila 1 de la matriz completa (L1-L4 + anti-patrón).

- **Step 1: Haz las 3 tareas del guion en Wanderlog**

Añade el vuelo (reenvía una confirmación real o mete uno a mano), decide dónde cenar, e intenta repartir el gasto. Fíjate en dónde te sentiste perdida: eso es el anti-patrón que ya detectaste ("confuso").

- **Step 2: Captura el patrón fuerte (L1)**

Screenshot de la mejor pantalla (probablemente el mapa con sitios guardados por día). Guárdala como `docs/research/img/wanderlog-L1.png`. Escribe en L1 la frase de por qué funciona y marca `[ROBAR: ___]` si hay un patrón claro.

- **Step 3: Rellena L2 y L4**

L2: ¿en qué es bueno (itinerario visual en mapa) y dónde le gana el bento (él no tiene gastos/chat/votos integrados)? L4: el quick win pequeño que le viste y a ti te falta.

- **Step 4: Escribe el anti-patrón**

La 1 cosa concreta que la hizo confusa (ej: "construcción manual del itinerario: arrastrar sitios y meter horas a mano"; "colaboración en vivo caótica"). Sé específica: es la que TripSquad NO hará.

- **Step 5: Guarda**

```bash
git add docs/research/competidores-matriz.md docs/research/img/wanderlog-L1.png
git commit -m "research(competidores): teardown Wanderlog completo (Task 2)"
```

- **Step 6: Verifica**

La sección 1 de la matriz tiene L1-L4 + anti-patrón, todos con texto real (no `_(...)_`), y existe la captura. Si un campo quedó vacío, o lo rellenas o anotas por qué no aplica.

---

## Tasks 3-7: Teardown del resto de hands-on (Días 2-4)

> Cada una es IDÉNTICA a la Task 2 en estructura (3 tareas del guion → captura L1 → L2/L4 → anti-patrón → commit → verifica). Cambia solo el foco. Repite el ciclo de 6 pasos de la Task 2 para cada una.

### Task 3: TripIt — foco parseo de documentos
- **Qué buscar en L1:** reenvías una confirmación de vuelo y mira cómo la parsea y la monta en el timeline. Ese es SU superpoder (mejor que Wanderlog). `[ROBAR: ___]` casi seguro.
- **L2:** le gana el bento porque TripIt es solo itinerario/docs, sin grupo real.
- **Commit:** `research(competidores): teardown TripIt (Task 3)`

### Task 4: Splitwise — foco split + qué NO copiar
- **L1:** escanea un recibo (la cena de 80€), mira cómo itemiza y asigna. Captura el flujo de "quién comió qué".
- **L4/anti-patrón clave:** Splitwise es el especialista. Anota qué de su split es table stakes (hay que tenerlo) y qué NO copiar (ej: si mete fricción de cuentas/pagos que tú no quieres).
- **Commit:** `research(competidores): teardown Splitwise (Task 4)`

### Task 5: Tricount — foco onboarding sin fricción (Europa)
- **L3 (el importante aquí):** Tricount deja empezar SIN cuenta. Cuenta los pasos hasta repartir el primer gasto. Ese es el patrón de activación a robar para el muro de "meter al squad".
- **Commit:** `research(competidores): teardown Tricount (Task 5)`

### Task 6: App de grupo (Troupe/Pilot) — foco estado por persona
- **L1/L2:** busca si tiene algo parecido a "quién ha hecho su parte" (reservar, pagar, confirmar). Es el wedge que detectaste. Si NO lo tiene bien (probable), eso CONFIRMA que es hueco abierto en el mercado.
- **Commit:** `research(competidores): teardown app de grupo (Task 6)`

### Task 7: IA-first (Mindtrip/Layla/ChatGPT) — benchmark de la Brújula
- **Ligero:** solo la tarea IA — pídele "planéame 3 días en Lisboa para 4 amigos". Mide: ¿qué tan bueno es? ¿qué le pedirías a la Brújula que esto NO hace? Captura la respuesta.
- **L2:** la Brújula le gana porque conoce el contexto del viaje (gastos, votos, itinerario del grupo); un chat genérico no.
- **Commit:** `research(competidores): benchmark IA-first (Task 7)`

---

## Task 8: Apple Cash bill-split (Día 4) — research secundaria, NO hands-on

**Files:**
- Modify: `docs/research/competidores-matriz.md` (sección 7)

**Interfaces:**
- Produces: fila de Apple Cash con dato de specs (no captura hands-on — es solo-EEUU).

- **Step 1: Lee las specs y mira 1-2 vídeos del flujo**

Fuentes: el artículo de Bloomberg (jun 2026) y cualquier demo en vídeo del bill-split de iOS 27. Busca: cómo asigna ítems por persona, cómo cobra (Messages/Wallet), y la limitación (solo Apple Cash = solo EEUU).

- **Step 2: Rellena la fila con L2 como foco**

L1: describe el flujo por specs (marca "por specs, no hands-on"). L2 (el importante): DÓNDE le gana el bento — Apple Cash es genérico y solo-EEUU; el tuyo funciona en Europa y sabe quién está en el viaje. Anti-patrón: no aplica (es feature de plataforma). Guarda captura de spec/vídeo si puedes en `img/apple-cash-spec.png`.

- **Step 3: Guarda**

```bash
git add docs/research/competidores-matriz.md docs/research/img/ 2>/dev/null
git commit -m "research(competidores): Apple Cash bill-split por specs (Task 8)"
```

- **Step 4: Verifica**

La sección 7 está rellena y marcada como "dato de specs". El Success Criteria del design doc permite esta excepción explícitamente.

---

## Task 9: Stack informal (Día 4, tarde) — el competidor REAL

**Files:**
- Modify: `docs/research/competidores-matriz.md` (sección 8)

**Interfaces:**
- Produces: fila del stack informal, tratada como 4 herramientas (doble tiempo).

- **Step 1: Haz las 3 tareas del guion con el stack informal**

Vuelo: pégalo en el chat de WhatsApp del grupo. Decisión: usa la **encuesta de WhatsApp** para votar dónde cenar (esto es tu benchmark de VOTACIONES, único sitio donde lo ves). Gasto: mételo en Splitwise. Fotos: un álbum compartido. Itinerario: un Google Doc.

- **Step 2: Rellena las 4 lentes pensando en el CONJUNTO**

L1: qué patrón de cada herramienta funciona (la encuesta de WhatsApp es clave). L2: aquí el bento gana MÁS que contra nadie — el stack informal es 4 apps sin costuras. L3: el onboarding del stack informal es cero fricción (ya lo tienen todos), y ESE es el listón real a batir. L4: qué da cada herramienta que a ti te falta.

- **Step 3: Anota el anti-patrón del stack**

El caos de tener el gasto en un sitio, la foto en otro, la decisión en un tercero. Ese caos ES tu oportunidad, pero anota también qué del stack informal la gente NO querrá abandonar (ej: el chat ya está en WhatsApp).

- **Step 4: Guarda**

```bash
git add docs/research/competidores-matriz.md
git commit -m "research(competidores): teardown stack informal incl. votaciones WhatsApp (Task 9)"
```

- **Step 5: Verifica que la matriz está COMPLETA**

Las 8 secciones tienen las 4 lentes + anti-patrón. Ningún `_(...)_` sin rellenar. Este es el gate antes de sintetizar.

---

## Task 10: Síntesis — los 4 entregables (Día 5)

**Files:**
- Create: `docs/research/hallazgos.md` (los 4 entregables)

**Interfaces:**
- Consumes: `competidores-matriz.md` (completa).
- Produces: `hallazgos.md` — lo que alimenta el front y el `/spec` posterior.

- **Step 1: Entregable 1 — la matriz ya está** (es `competidores-matriz.md`). Solo enlázala desde `hallazgos.md`.

- **Step 2: Entregable 2 — lista de robo priorizada**

En `hallazgos.md`, lista todos los `[ROBAR: ___]` de la matriz. Ordénalos por impacto en el front. Marca cada uno como **FOSO** (costura de integración que nadie tiene) o **TABLE STAKES** (hay que tenerlo pero no diferencia). Regla de filtro: si viola "premium, no hoja de cálculo", va fuera.

- **Step 3: Entregable 3 — los 3 momentos mágicos**

Escribe los 3 guiones de las costuras que ninguna app tiene (candidatos: votar en el chat → entra al itinerario → el gasto se reparte solo; recibo→split-en-contexto; tablero de "quién ya reservó"). Cada uno en 2-3 frases: qué ve el usuario y por qué ninguna app puede copiarlo. Estos son candidatos al PRIMER flujo del front.

- **Step 4: Entregable 4 — lista de quick wins**

Junta todos los L4 de la matriz. Ordénalos por impacto ÷ esfuerzo (S/M ya anotado). Esta es la lista de relleno barato que se ataca en paralelo al construir los flujos grandes.

- **Step 5: Marca las dependencias front→back**

Al final de `hallazgos.md`, por cada momento mágico y cada pieza de front grande, anota si NECESITA back que no existe (recibo→split OCR y tablero-de-reservas NO tienen back; fotos/brújula son stub → beads 7n3/3dk). Esto conecta con el mapa de huecos back+front y evita descubrirlo a mitad del front.

- **Step 6: Guarda y cierra**

```bash
git add docs/research/hallazgos.md docs/research/
git commit -m "research(competidores): sintesis final — 4 entregables + dependencias front-back (Task 10)"
```

- **Step 7: Verifica el Success Criteria del design doc**

Confirma: matriz completa con la misma plantilla (8×4+anti) · lista de robo distingue foso vs table stakes · 3 momentos mágicos escritos · lista de quick wins ordenada · dependencias front→back marcadas · terminado en ≤1 semana · cero patrón que viole "premium".

---

## Self-Review (cobertura del design doc)

- **3 lentes originales + la 4ª (quick wins que Andrea pidió):** cubiertas en cada teardown (Tasks 2-9) y en los entregables 2-4 (Task 10). ✅
- **Los 8 competidores:** una tarea cada uno (o agrupados por día), todos con la misma plantilla. ✅
- **Anti-patrón "no confuso":** capturado explícitamente en cada teardown, foco en Task 2 (Wanderlog). ✅
- **Dependencias front→back:** Task 10 Step 5, conecta con el mapa de huecos. ✅
- **Timebox 1 semana:** cronograma Día 1-5 mapeado a Tasks 0-10. ✅
- **Apple Cash como secundaria:** Task 8 lo trata por specs, no hands-on, sin romper el "misma plantilla" (excepción documentada). ✅

## Notas de ejecución

- Esto lo ejecuta Andrea (humano) por el juicio de flujo. Un agente PUEDE ayudar en: Task 8 (recopilar specs de Apple Cash), y en la Task 10 puede ordenar/formatear los entregables una vez la matriz está rellena. El teardown hands-on (Tasks 1-7, 9) es humano.
- Si una app de pago bloquea justo el feature a ver (ej: Wanderlog Pro para el parseo de Gmail), NO pagues sin preguntar a Andrea: anótalo como "bloqueado por paywall" y sigue.
- Si el Día 1 se desborda (fricción de invitación de grupo), estira el sprint a 1.5 semanas antes que recortar teardowns: la comparabilidad vale más que la velocidad.
