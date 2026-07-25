# Matriz de competidores — TripSquad

> Runbook: `docs/superpowers/plans/2026-07-25-investigacion-competidores.md`
> Guion común: `viaje-de-prueba.md`
> Regla: misma plantilla para las 8. Rellena reemplazando los `_(...)_`. Capturas en `img/`.

**Leyenda:** `[ROBAR: ...]` = patrón a copiar · **FOSO** = costura que nadie tiene · **TS** = table stakes · S/M = esfuerzo.
**🔍 Desk** = dato ya verificado por búsqueda (2026-07-25), no necesita tu tiempo. **✍️ Hands-on** = necesita tu juicio de flujo con la app abierta.

---

## 1. Wanderlog  _(hands-on WEB · foco: itinerario + anti-patrón "confuso" · teardown 2026-07-25)_
- **🔍 Desk:** planificador itinerario+mapa. Importa docs reenviando el email de confirmación o conectando Gmail (Pro) → parsea vuelos/hoteles/coches/actividades. Parseo de PDF **débil vs TripIt**. Pro ~40$/año (offline + export PDF). Fuerte en: guardar sitios y agruparlos por día sobre el mapa ("menos torpe que Google My Maps, más visual que TripIt"). Quejas: rendimiento #1, el móvil tiene menos que la web, **IA floja** (sin botón "genérame 3 días", todo manual), y **colaboración en vivo caótica** con varios editando.
- **L1 Patrones ✍️ (hands-on):** **vista dual lista↔mapa**: a la izquierda "Places to visit" (listas ilimitadas, "Add a place"), a la derecha el mapa vivo de Google con cada sitio pinchado. El patrón fuerte es la **atribución colaborativa**: el coach-mark "Collaborate to add places" muestra pins "added by Nancy / added by Debby / added by you" → sabes de un vistazo **quién metió cada sitio**. Sidebar: AI Assistant · Overview (Explore/Notes/Places) · Itinerary · Budget. **[ROBAR: la vista dual lista↔mapa + la atribución "quién añadió qué" por persona]** (esto conecta con el instinto de "quién ya hizo su parte"). · captura: `img/wanderlog-L1.png`
- **L2 Posicionamiento 🔍 CORREGIDO (hands-on):** ⚠️ el desk decía "sin gastos" y **es FALSO**: Wanderlog TIENE módulo Budget con `Add expense`, **`Group balances`**, `View breakdown`, `Add tripmate` y orden de gastos por categoría. Pero es un **tracker de presupuesto anexo**, no un settle-en-contexto: no conecta con votos/chat/recibo ni sabe "quién estaba en la cena". El bento gana **por integración de la costura** (voto→itinerario→gasto), no porque el rival carezca de gastos. Su IA manual sigue siendo su flanco vs la Brújula.
- **L3 Onboarding ✍️ (hands-on) — fricción MÍNIMA:** crear viaje = **0 pasos de cuenta**: solo el destino (autocompletado), fechas OPCIONALES, invitar OPCIONAL. Al pulsar "Start planning" salta un muro "Sign up to save your trip" **pero con "Skip and sign up later"** → caes en un planner 100% funcional con URL compartible (`/plan/qlckrsabzbafheml`). Invitas tripmates por email o link de compartir. La activación **no muere**: das valor antes de pedir cuenta. Captura: `img/wanderlog-L3-onboarding.png`
- **L4 Quick wins que nos faltan ✍️ (hands-on):** (1) **"Recommended places" + "Explore"**: al abrir Lisboa ya ofrece "Best attractions/restaurants in Lisbon" e itinerarios de la comunidad y de Google/Tripadvisor/Lonely Planet — arranque no-en-blanco (esfuerzo **M**, requiere fuente de contenido). (2) **Tipos de reserva tipados** (Flight/Lodging/Rental car/Train/Ferry/Cruise/Bus) como bloques con parseo, no texto libre (**S**). (3) header con foto de portada del viaje editable (**S**, toque premium barato).
- **Anti-patrón ✍️ (hands-on) CONFIRMADO:** construcción **manual sitio a sitio** ("Add a place" de uno en uno) y el **itinerario nace vacío** ("Your itinerary is empty. Select a start and end date to organize your days") → hay que meter fechas y arrastrar sitios a días a mano. Además, al entrar, **coach-marks tapan la pantalla** ("Collaborate to add places" + "Add some places" a la vez). Eso es densidad/fricción, no claridad → TripSquad NO hará arranque en blanco ni tutoriales que tapen.

## 2. TripIt  _(hands-on · foco: parseo de PDF/email de vuelos)_
- **🔍 Desk:** el REY del parseo. Reenvías confirmaciones y arma un itinerario maestro día a día automático; alertas de vuelo en tiempo real; guarda todos los números de confirmación en un sitio.
- **L1 Patrones ✍️:** _(reenvía una confirmación real y mira cómo la monta en el timeline — este es su superpoder + [ROBAR: ___])_ · captura: `img/tripit-L1.png`
- **L2 Posicionamiento 🔍:** solo itinerario/docs, **sin grupo real ni gastos** → el bento gana. Su parseo es lo que TripSquad debe igualar (table stakes), no su alcance.
- **L3 Onboarding ✍️:** _(...)_
- **L4 Quick wins que nos faltan ✍️:** _(...)_
- **Anti-patrón ✍️:** _(...)_

## 3. Splitwise  _(hands-on · foco: split + qué NO copiar)_
- **🔍 Desk:** 100M+ descargas, el especialista de "quién debe a quién" en el tiempo. Escanea recibo → detecta los ítems → los asignas a cada amigo (perfecto para restaurante/súper).
- **L1 Patrones ✍️:** _(escanea la cena de 80€ — cómo itemiza y asigna "quién comió qué" + [ROBAR: ___])_ · captura: `img/splitwise-L1.png`
- **L2 Posicionamiento 🔍:** es un LIBRO DE CUENTAS, no un viaje: sin itinerario, chat, votos ni fotos. El split-en-contexto del bento (sabe quién está en el viaje, qué votasteis) es el FOSO.
- **L3 Onboarding ✍️:** _(...)_
- **L4 Quick wins que nos faltan ✍️:** _(...)_
- **Anti-patrón ✍️:** _(qué de su split NO copiar — vigila fricción de cuentas/pagos que te aleje del "premium, no hoja de cálculo")_

## 4. Tricount  _(hands-on · foco: onboarding sin fricción, Europa)_
- **🔍 Desk:** líder de split en Europa. **Sin cuenta** para lo básico, gratis en core, ahora con escaneo de recibos (OCR), modo oscuro y export Excel/PDF.
- **L1 Patrones ✍️:** _(...)_ · captura: `img/tricount-L1.png`
- **L2 Posicionamiento 🔍:** mismo caso que Splitwise (solo gastos) pero con onboarding europeo sin fricción → su lección es de activación, no de alcance.
- **L3 Onboarding ✍️ (EL importante):** _(empieza SIN cuenta — cuenta los pasos hasta el 1er gasto. Este es el patrón de activación a robar para el muro de "meter al squad" [ROBAR: ___])_
- **L4 Quick wins que nos faltan ✍️:** _(...)_
- **Anti-patrón ✍️:** _(...)_

## 5. App de grupo (Troupe/Pilot — elegida: ___)  _(hands-on · foco: estado por persona)_
- **🔍 Desk:** apps grupo-first. Pilot guarda ficheros/docs del viaje. Algunas asignan TAREAS a miembros (reservar hotel, transporte) para repartir el trabajo. Pero el **estado de reserva por persona** ("quién ya compró el vuelo") como tablero vivo es débil en todo el mercado.
- **L1 Patrones ✍️:** _(¿tiene algo tipo "quién ha hecho su parte" (reservar/pagar/confirmar)? + [ROBAR: ___])_ · captura: `img/grupo-L1.png`
- **L2 Posicionamiento 🔍+✍️:** si NO tiene bien el estado-por-persona (probable), **CONFIRMA que el wedge está abierto**. Anota exactamente qué le falta.
- **L3 Onboarding ✍️:** _(...)_
- **L4 Quick wins que nos faltan ✍️:** _(...)_
- **Anti-patrón ✍️:** _(...)_

## 6. IA-first — **elegida: Mindtrip**  _(web · benchmark de la Brújula · teardown parcial 2026-07-25)_
- **🔍 Desk:** planificadores IA-first que generan itinerarios por chat. Su límite: NO conocen el contexto real de TU grupo (gastos, votos, quién está dentro).
- **L1 Patrones ✍️ (hands-on, Chrome real — CAPTCHA pasado):** prompt "planéame 3 días en Lisboa para 4 amigos, 12-14 sep 2026" → en **~20s** genera "Escapada de tres días a Lisboa" con: header de contexto (Lisboa · fechas · **4 viajeros** · Presupuesto), **3 días clusterizados por barrio** (D1 Baixa/Chiado + miradores, D2 Alfama/histórica, …), cada bloque Morning/Afternoon/Evening con venues **verificados** (Arco da Rua Augusta, Carmo Convent, Castelo de São Jorge, cena marisco en Cervejaria Ramiro), **mapa vivo a la derecha** con todo pinchado + precios (hotel $7.465, restos $$), y **auto-añade los sitios al viaje** ("Viaje 5", toast "Cervejaria Ramiro añadido a su viaje"). Calidad alta y geográficamente sensata. **Este es el listón de la Brújula.** Lo que a la Brújula le pediría que Mindtrip NO hace: partir del **estado real del grupo** (votos/gastos/quién está dentro) en vez de un plan solo genérico. **[ROBAR/IGUALAR: generación IA de itinerario clusterizado-por-día con auto-add al viaje y mapa vivo — table stakes de la Brújula]** · captura: `img/ia-L1.png`
- **L2 Posicionamiento ⚠️ HALLAZGO GORDO (afila la tesis) — de la landing de Mindtrip:** Mindtrip **NO es un chat genérico**: es el competidor **más cercano al bento** de los 8. Su propia web anuncia: *"Plan with your crew — invite friends, start a group chat, build an itinerary that works for everyone, no endless group texts"* + *"upload/forward receipts to receipts@mindtrip.ai"* + *"collaboration tools: plan in real time, chat as a group, tag @Mindtrip for suggestions that balance everyone's vibes"*. O sea: **group chat + itinerario + IA + recibos + colaboración en vivo, integrados.** La suposición del desk ("la IA no conoce el contexto del grupo") **es más débil de lo pensado**: Mindtrip SÍ tiene contexto de grupo. → El foso de TripSquad **se estrecha** a tres cosas concretas que Mindtrip NO tiene: (1) **liquidación real** (sus recibos son almacén/organización, no "quién debe a quién" ni settle), (2) **votaciones estructuradas** (ellos: chat + sugerencias de IA, no un voto con resultado), (3) **Europa + no-agente-de-viajes-US** (Mindtrip se posiciona como AI travel agent con reservas/afiliación). Esto es lo más importante de toda la investigación: **el diferenciador NO es "somos un bento y ellos no" — es el motor de settle + la decisión estructurada + el mercado.**
- **L3 Onboarding ✍️:** landing → "Start chatting" lleva a `/chat`, y ahí salta el CAPTCHA antes de dejar escribir. Fricción de bot alta (esperable en producto IA); para un humano es "empieza a chatear" directo. iOS app aparte.
- **L4 Quick wins que nos faltan ✍️ (de la landing):** (1) **Google Pins import** — importar sitios guardados de Google Maps y convertirlos en colección del viaje (**M**, gancho de arranque no-en-blanco). (2) **Events cercanos** ("conciertos, mercados, family fun que encajan con tu vibe") como capa viva del destino (**M**). (3) **Start Anywhere®**: pega un link/foto/PDF de contenido de viaje y te lo convierte en itinerario (**M/L**).
- **Anti-patrón ✍️ (parcial):** posicionamiento de **AI travel agent con reservas/afiliación** (monetiza empujando hoteles/tours). El riesgo a NO copiar: que la IA empuje a reservar por comisión y el usuario sienta que le venden, no que le ayudan. TripSquad: la Brújula aconseja, no vende.

## 7. Apple Cash bill-split (iOS 27 / watchOS 27)  _(SECUNDARIO · por specs — COMPLETADO 2026-07-25)_
- **L1 Patrones (🔍 por specs, no hands-on):** foto al recibo → toca/selecciona ítems y los asigna a cada participante (incl. impuestos y propina) → Apple Cash calcula la parte de cada uno y **envía peticiones de pago personalizadas por Messages o Wallet**; se puede aprobar desde el Apple Watch. Parseo del recibo por IA on-device. Llega en **iOS 27 / watchOS 27** (anunciado jun 2026). Fuentes: Bloomberg, PYMNTS, MacDailyNews.
- **L2 Posicionamiento (🔍 EL foco) — FOSO:** atado a **Apple Cash = solo EEUU** (requiere cuenta/banco US). En Europa (tu mercado) **no existe**. Y aunque existiera: es genérico, no sabe que estás de viaje con este grupo, no conecta con itinerario/votos. El recibo-en-contexto del bento vale 10x y **funciona donde Apple no llega**. Amenaza real en EEUU; hueco abierto en Europa.
- **L3 Onboarding:** n/a — feature de plataforma (ya integrada en Wallet/Messages para quien tiene Apple Cash).
- **L4 Quick wins que nos faltan:** el flujo "toca el ítem → asígnalo → auto-suma" es el patrón de UX a igualar en el split del bento (TS). Aprobar desde el reloj no aplica a v1.
- **Anti-patrón:** n/a (no es competidor de producto, es de plataforma).

## 8. Stack informal (WhatsApp + Splitwise + álbum + Google Doc)  _(hands-on · el competidor REAL — doble tiempo, son 4 herramientas)_
- **🔍 Desk:** es lo que la mayoría YA usa: WhatsApp (chat + fotos + votos de facto vía **encuesta de WhatsApp**) + Splitwise (gastos) + un álbum compartido (fotos) + un Google Doc (itinerario). Gratis, ya instalado, "funciona".
- **L1 Patrones ✍️:** _(qué patrón de cada herramienta funciona — la ENCUESTA de WhatsApp es tu único benchmark de VOTACIONES [ROBAR: ___])_ · captura: `img/informal-L1.png`
- **L2 Posicionamiento 🔍:** aquí el bento gana MÁS que contra nadie: son **4 apps sin costuras** entre ellas. La decisión está en un sitio, el gasto en otro, la foto en un tercero.
- **L3 Onboarding 🔍:** cero fricción (ya lo tienen todos) → **ESE es el listón real a batir**. TripSquad tiene que dar más valor que la suma de 4 apps que ya usan gratis.
- **L4 Quick wins que nos faltan ✍️:** _(qué da cada herramienta que a ti te falta)_
- **Anti-patrón 🔍+✍️:** el caos de gasto/foto/decisión en 3 sitios ES tu oportunidad. Pero anota qué NO querrán abandonar (ej: el chat ya vive en WhatsApp — el reto de retención).
