# Matriz de competidores — TripSquad

> Runbook: `docs/superpowers/plans/2026-07-25-investigacion-competidores.md`
> Guion común: `viaje-de-prueba.md`
> Regla: misma plantilla para las 8. Rellena reemplazando los `_(...)_`. Capturas en `img/`.

**Leyenda:** `[ROBAR: ...]` = patrón a copiar · **FOSO** = costura que nadie tiene · **TS** = table stakes · S/M = esfuerzo.
**🔍 Desk** = dato ya verificado por búsqueda (2026-07-25), no necesita tu tiempo. **✍️ Hands-on** = necesita tu juicio de flujo con la app abierta.

---

## 1. Wanderlog  _(hands-on · foco: itinerario + anti-patrón "confuso")_
- **🔍 Desk:** planificador itinerario+mapa. Importa docs reenviando el email de confirmación o conectando Gmail (Pro) → parsea vuelos/hoteles/coches/actividades. Parseo de PDF **débil vs TripIt**. Pro ~40$/año (offline + export PDF). Fuerte en: guardar sitios y agruparlos por día sobre el mapa ("menos torpe que Google My Maps, más visual que TripIt"). Quejas: rendimiento #1, el móvil tiene menos que la web, **IA floja** (sin botón "genérame 3 días", todo manual), y **colaboración en vivo caótica** con varios editando.
- **L1 Patrones ✍️:** _(confirma en vivo el mapa con sitios por día — ¿ese es el patrón fuerte? + [ROBAR: ___])_ · captura: `img/wanderlog-L1.png`
- **L2 Posicionamiento 🔍:** solo itinerario, sin gastos/chat/votos integrados → **el bento gana por integración**. Su IA manual es su flanco; tu Brújula que hace el trabajo es el contraste.
- **L3 Onboarding ✍️:** _(nº pasos hasta grupo dentro / dónde muere / qué pide antes de dar valor)_
- **L4 Quick wins que nos faltan ✍️:** _(1-2, con esfuerzo S/M)_
- **Anti-patrón 🔍+✍️:** construcción MANUAL del itinerario (arrastrar sitios, meter horas a mano) + multi-editor caótico. _(confirma en vivo QUÉ paso concreto te perdió — es lo que TripSquad NO hará)_

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

## 6. IA-first (Mindtrip/Layla/ChatGPT — elegida: ___)  _(hands-on ligero · benchmark de la Brújula)_
- **🔍 Desk:** planificadores IA-first que generan itinerarios por chat. Su límite: NO conocen el contexto real de TU grupo (gastos, votos, quién está dentro).
- **L1 Patrones ✍️:** _(pídele "planéame 3 días en Lisboa para 4 amigos" — ¿qué tan bueno? ¿qué le pedirías que NO hace?)_ · captura: `img/ia-L1.png`
- **L2 Posicionamiento 🔍:** la Brújula gana porque vive DENTRO del viaje (ve el itinerario, los gastos, los votos del grupo); un chat genérico no. Este es el benchmark de tu pilar diferencial.
- **L3 Onboarding ✍️:** _(n/a o muy corto)_
- **L4 Quick wins que nos faltan ✍️:** _(...)_
- **Anti-patrón ✍️:** _(...)_

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
