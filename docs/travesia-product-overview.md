# Travesía — Qué es la app y para qué sirve

## La idea central

Travesía es una app para iOS diseñada para grupos de amigos que viajan juntos. Su premisa es simple: viajar en grupo debería ser la mejor experiencia posible, y hoy en día está lleno de fricción innecesaria — conversaciones dispersas en WhatsApp, hojas de cálculo para los gastos, votaciones en forma de caos, itinerarios que nadie actualiza.

Travesía junta todo eso en un solo lugar y le da forma de experiencia, no de herramienta.

El nombre lo dice todo: no es una app de gestión de viajes, es una app sobre el viaje en sí. La travesía — desde que se empieza a planear hasta que se vuelve a casa.

---

## El problema que resuelve

Cuando un grupo de personas decide viajar juntas, el proceso real se ve así:

- Deciden el destino por mensaje privado entre 4 conversaciones de WhatsApp distintas
- Alguien arma una hoja de Google Sheets para los gastos que nadie actualiza bien
- Los deudores no saben exactamente cuánto deben ni a quién
- El itinerario vive en una nota de iPhone o un PDF que alguien mandó al grupo
- Las fotos quedan regadas entre Instagram Stories y los álbumes personales de cada quien
- Nadie sabe quién confirmó el hotel ni quién falta por pagar

Travesía resuelve todo eso. Un lugar, un squad, un viaje.

---

## Cómo funciona — el flujo completo

Un usuario entra a la app y ve su pantalla de inicio. Desde ahí puede crear un viaje nuevo o unirse a uno con código de invitación. Una vez dentro del viaje, tiene acceso a todas las herramientas del squad: chat, itinerario, gastos, votaciones, fotos, y la lista de miembros. Si tiene acceso premium, también tiene a Brújula — el copiloto IA del viaje.

---

## Las pantallas — qué hace cada una y por qué existe

### Onboarding

La primera vez que alguien abre Travesía, pasa por un onboarding narrativo de 6 capítulos. No es un tutorial de funciones — es una historia. Los capítulos se llaman: El Sueño, El Destino, El Crew, Las Herramientas, El Viaje, y Únete a la Historia.

El objetivo es que antes de usar la app, el usuario entienda qué tipo de producto es Travesía. No es un gestor de tareas con vuelos. Es una compañía de viaje.

Al final del onboarding, el usuario ve una boarding pass — su primera experiencia visual con el producto antes de registrarse.

---

### Home — Pantalla de inicio (3 estados)

La pantalla principal es diferente dependiendo del momento del usuario con la app. Hay tres versiones:

**Estado 1 — Con viaje próximo**
El usuario tiene un viaje planeado pero todavía no ha llegado. La pantalla muestra un hero card con el destino, un contador de días restantes, y widgets del viaje en formato bento: presupuesto, próxima actividad confirmada, último mensaje del chat del squad, clima del destino, y el tipo de cambio de moneda.

El por qué: el usuario quiere sentir el viaje acercarse. La anticipación es parte de la experiencia.

**Estado 2 — En viaje (modo activo)**
El usuario está en el destino, viajando ahora mismo. La pantalla cambia a fondo oscuro (navy) con los mismos widgets pero en modo nocturno, priorizando la información que se necesita en tiempo real: qué sigue en el itinerario hoy, el balance del grupo, el chat activo, el clima local.

El por qué: cuando estás viajando no tienes tiempo. Necesitas la info de un vistazo.

**Estado 3 — Sin viaje (Discovery)**
El usuario no tiene ningún viaje activo. La pantalla le muestra destinos populares, tendencias de viaje, y un acceso directo a Brújula IA para explorar ideas. Hay un carrusel de destinos curados con información de experiencias disponibles en cada lugar.

El por qué: la app no debe sentirse vacía cuando no hay viaje activo. Debe mantenerte en modo viajero.

---

### Crear viaje

Un wizard de 4 pasos que guía al usuario desde la idea hasta tener un viaje armado con su squad.

**Paso 1 — Destino:** El usuario escribe a dónde quiere ir. Hay sugerencias de destinos populares. También selecciona las fechas de salida y regreso, y la app le calcula automáticamente cuántas noches son.

**Paso 2 — Squad:** Elige quién va. Puede buscar entre sus contactos o invitar por link. Ve un stack de avatares que se va llenando conforme agrega personas.

**Paso 3 — Presupuesto:** Define el rango de gasto estimado del viaje con un slider, y elige el estilo del viaje — playa, ciudad, naturaleza, cultura, fiesta, relajado.

**Paso 4 — Módulos:** Activa las herramientas que quiere para ese viaje. No todos los viajes necesitan todo. Puede activar o desactivar: Gastos, Votaciones, Fotos, Chat, Mapa, y Brújula IA.

Al terminar, hay una animación de celebración (confeti) y el viaje ya existe para todo el squad.

El por qué: crear un viaje no debería ser burocrático. El wizard convierte una decisión casual de WhatsApp en algo concreto, compartido y organizado en menos de dos minutos.

---

### Unirse a un viaje

Cuando alguien en el squad crea un viaje y manda el link de invitación, los demás entran aquí. La pantalla muestra una vista previa del viaje: foto del destino, nombre del viaje, fechas, quién lo organiza, quién ya confirmó que va, y los highlights planeados.

El usuario ve todo antes de confirmar. Y cuando confirma, hay confeti.

El por qué: unirse a un viaje debería sentirse especial, no como aceptar una solicitud de calendario.

---

### Detalle del viaje — TripBento

Una vez dentro de un viaje, esta es la pantalla central. Muestra el viaje en formato de bento grid — un mosaico de tarjetas que cada una lleva a una sección distinta: itinerario del día, chat, gastos, votaciones, fotos, squad.

Arriba hay un hero con la foto del destino y los datos principales del viaje. Abajo, las cards se organizan por relevancia según lo que esté pasando en ese momento.

El por qué: el viaje tiene muchas dimensiones — logística, social, financiera. El bento las muestra todas a la vez sin jerarquías rígidas, permitiendo que cada usuario acceda a lo que le importa en ese momento.

---

### Chat del squad

Un chat grupal dentro del contexto del viaje. Tiene lo básico de cualquier chat — mensajes, emojis, fotos — pero con una diferencia importante: los polls de votación se renderizan directamente dentro del chat como tarjetas interactivas, y los links de actividades o lugares muestran una preview con imagen.

El chat vive en el contexto del viaje, no es un chat genérico. Eso significa que no se mezcla con otras conversaciones y los mensajes siempre son relevantes al tema.

El por qué: mover la conversación del squad fuera de WhatsApp y dentro del viaje significa que todo lo que se dice ahí es accionable — se puede convertir en actividad, en votación, en gasto.

---

### Itinerario

Una vista de cronograma del viaje, organizada por días. Hay un selector horizontal de días arriba, y al seleccionar uno aparece la lista de actividades en formato de timeline vertical con íconos, horarios, avatares de quién confirmó cada actividad, y el clima del día.

Las actividades pueden ser cualquier cosa: restaurantes, tours, vuelos, tiempo libre, reuniones de squad.

El por qué: todo grupo de viajeros necesita saber qué sigue. El itinerario de Travesía no es un PDF estático — es vivo, editable por el squad, y conectado con los datos reales del destino.

---

### Detalle de actividad

Cuando alguien toca una actividad del itinerario, abre esta pantalla. Muestra una foto grande del lugar, el nombre, la ubicación, el rating, y los datos concretos: a qué hora, cuánto dura, cuánto cuesta por persona. También muestra quién propuso esa actividad, cuántas personas del squad están interesadas, y una sección de "¿quién va?" con el estado de confirmación de cada miembro.

Desde aquí se puede votar por la actividad o agregarla directamente al itinerario.

El por qué: antes de confirmar una actividad, el squad necesita verla, evaluarla juntos, y decidir democráticamente si va. Esta pantalla es ese espacio de decisión.

---

### Votaciones

El módulo de decisiones democráticas del squad. Muestra la lista de votaciones activas — cada una como una tarjeta con la pregunta, las opciones, los porcentajes actuales, y cuánto tiempo queda para votar.

Votar es simple: tap en una opción. El resultado se actualiza en tiempo real para todos los miembros del squad.

**Crear una votación** abre un formulario donde se escribe la pregunta, se agregan las opciones (A, B, C...), se elige si la votación es de selección única o múltiple, y se define el tiempo límite (2h, 12h, 24h, 48h).

El por qué: en un grupo de personas, tomar decisiones por mensaje genera caos. La votación formaliza el proceso, hace visible el resultado, y le da cierre a la discusión.

---

### Gastos — Hub central

Un hub de cuatro pestañas que centraliza todo lo financiero del viaje.

**Pestaña Actividad:** El feed cronológico de todos los gastos registrados. Cada gasto muestra la categoría (comida, transporte, alojamiento, etc.), quién pagó, el monto, y la fecha. Un historial claro.

**Pestaña Balances:** Quién debe cuánto a quién. Muestra el balance neto de cada miembro del squad en términos simples: Carlos debe $340 MXN, Mariana tiene saldo a favor de $120 USD. Los números se muestran en verde (a favor) o rojo (debe). Desde aquí se puede iniciar el proceso de liquidación.

**Pestaña Insights:** Visualización del gasto del viaje — un donut chart por categoría, el ranking de quién ha gastado más, el promedio por día, y el día más caro del viaje.

**Pestaña Grupo:** El total gastado por cada miembro y su porcentaje del gasto total del viaje.

El por qué: los gastos compartidos son la fuente de fricción número uno en los viajes grupales. Travesía los hace transparentes, justos, y fáciles de liquidar.

---

### Agregar gasto

Pantalla para registrar un gasto nuevo. Hay un display grande del monto con botones de acceso rápido (+100, +250, +500). El usuario agrega el título del gasto, selecciona la categoría, elige quién pagó (cualquier miembro del squad), y define cómo se divide.

La división se configura en la pantalla de Split.

El por qué: agregar un gasto debe ser rápido. El momento de registrarlo es en el restaurante, en el taxi, en la taquería — no horas después cuando nadie recuerda exactamente cuánto fue.

---

### División de gastos

Cuando se agrega un gasto, se define cómo se divide entre los miembros del squad. Hay tres modos:

**Igual:** Se divide en partes iguales entre todos. Hay opción de excluir a alguien si no participó.

**Porcentaje:** Cada persona tiene un slider o input de porcentaje. La suma debe dar 100%.

**Por items:** Si la cuenta tiene items distintos (ella pidió el ceviche, él la pasta, etc.), se pueden desglosar y asignar individualmente.

El por qué: no todos los gastos se dividen igual. Una cena puede tener consumos muy distintos por persona. Este módulo hace que la división sea justa sin que nadie tenga que hacer las cuentas manualmente.

---

### Liquidación (Settlement)

Cuando alguien quiere cerrar cuentas con el squad, esta pantalla le muestra exactamente los pagos mínimos necesarios para que todos queden en cero. Por ejemplo: "Carlos paga a Andrea $340 MXN" y "Mariana paga a Diego $220 MXN".

Cada pago sugerido se puede confirmar cuando se hace efectivo. Conforme se van confirmando, la pantalla va mostrando el progreso. Cuando todos los pagos están confirmados, aparece un estado de celebración: "Todo saldado".

El por qué: calcular quién le debe qué a quién en un grupo de 4 personas ya es complicado. En un grupo de 8, con gastos en distintas monedas, es imposible hacerlo a mano. Travesía lo resuelve automáticamente con el algoritmo óptimo de liquidación.

---

### Fotos del viaje

Una galería compartida del squad, organizada por días. Las fotos se suben desde el teléfono de cada miembro y quedan en el álbum compartido del viaje, disponible para todos.

El por qué: al terminar un viaje, las fotos quedan regadas en 8 iPhones distintos. Travesía crea el álbum de grupo automáticamente durante el viaje, no después.

---

### Squad

La lista de miembros del viaje. Muestra el avatar, nombre, y rol de cada persona (organizador, miembro), junto con su balance financiero en el viaje. También hay un botón para invitar a más personas al squad.

El por qué: en cualquier momento del viaje, cualquier miembro debe poder ver quiénes son los demás, qué rol tienen, y cómo están parados financieramente.

---

### Brújula — Copiloto IA del viaje

Brújula es el asistente inteligente integrado dentro de Travesía. Es una funcionalidad premium con cuatro modos distintos:

**Chat:** Conversación con la IA. El usuario puede preguntarle cualquier cosa del destino — "¿qué barrios recomiendas para comer en Tokio?", "¿hay algún museo cerca de nuestro hotel?", "¿cuánto cuesta aproximadamente un taxi del aeropuerto al centro?". Brújula responde con información contextualizada al viaje.

**Explorar:** Una cuadrícula de lugares y experiencias en el destino, filtrada por categorías (comer, hacer, dormir). El usuario puede guardar lugares de interés o agregarlos al itinerario.

**Build:** El usuario describe el viaje con palabras — "4 días en Barcelona, nos gusta el arte y la buena comida, presupuesto medio" — y Brújula genera un itinerario completo en tiempo real, revelando las fases de generación paso a paso.

**Itinerario IA:** Una vista del itinerario generado por Brújula con un selector horizontal de días y un timeline vertical de actividades. Pensado como punto de partida que el squad puede ajustar a su gusto.

**Paywall:** El acceso a Brújula requiere suscripción premium. La pantalla de paywall compara el plan gratuito con el premium y explica las diferencias.

El por qué: planear un itinerario desde cero es trabajo. Brújula no lo hace por ti — lo hace contigo. El squad sigue siendo quien decide, pero Brújula elimina la fricción de investigar, comparar y organizar.

---

### Perfil

La pantalla personal del usuario dentro de Travesía. Muestra su foto, nombre, número de viajes completados, squads activos, y memorias (fotos acumuladas). Desde aquí accede a sus configuraciones personales:

**Preferencias:** Moneda predeterminada (MXN, USD, EUR), idioma (español/inglés), y si Brújula IA está activada o no.

**Notificaciones:** Control granular de qué notificaciones recibir — mensajes del squad, recordatorios de actividades, votos pendientes, nuevos gastos.

**Privacidad:** Visibilidad del perfil dentro de squads, permiso de ubicación compartida, y la opción de eliminar la cuenta.

**Ayuda:** Estado del servicio en tiempo real, preguntas frecuentes, y link de contacto al soporte.

---

## Lo que se quiere lograr

Travesía no quiere ser la app más completa de viajes. Quiere ser la app con la que un grupo de amigos realmente quiera viajar.

La diferencia es importante. Las apps de gestión de viajes son exhaustivas y frías. Travesía apuesta por ser completa en lo que importa (gastos, decisiones, comunicación, itinerario) y cálida en cómo lo presenta. Los viajes en grupo son una de las experiencias más ricas que existen — Travesía debe estar a la altura de esa experiencia.

El objetivo final es que cuando alguien regrese de un viaje, Travesía haya sido una parte natural de cómo lo vivió con su squad. No algo que tuvieron que usar — algo que les ayudó a disfrutarlo más.
