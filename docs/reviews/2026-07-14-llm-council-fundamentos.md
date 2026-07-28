---
tipo: revisión externa (NO es un ADR — no decide, critica)
fecha: 2026-07-14
método: LLM Council (5 asesores independientes + 3 peer reviews anónimos)
skill: https://github.com/aiwithremy/claude-skills-llm-council
pregunta de Andrea: "¿está bien hecho, o son cimientos mal calculados?"
---

# Veredicto del consejo sobre los fundamentos del backend (Fase R)

**Veredicto: bien razonados, MAL SECUENCIADOS.** Los 3 revisores anónimos eligieron por
unanimidad la misma respuesta como la más fuerte (The Executor).

## La distinción que lo ordena todo

| | Construir para ESCALA (prematuro) | Construir para CORRECCIÓN (no prematuro) |
|---|---|---|
| Qué es | PowerSync, outbox, ETag, STRIDE 11 filas, CRDTs, backend Swift único escritor | Motor de saldos: Int64 céntimos, largest remainder, dedupe, FX congelado, MiembroId |
| Si se omite hoy | Nada. Se añade cuando duela. | La app miente sobre el dinero de tus amigos. Fin. |
| Coste hoy | 8-12 semanas sin un usuario | ~300 líneas de Swift puro, sin BD. Una semana. |

## Acciones recomendadas

1. **Motor de saldos, esta semana.** Swift puro, sin backend. Es donde el rigor ya se paga.
2. **A los otros 7 ADRs se les pone CRITERIO DE ACTIVACIÓN, no se borran.** La herramienta la
   inventó la propia fábrica (ADR-0013: "CRDTs cuando >2% de escrituras den 412"). Compatible
   con append-only: no se re-litiga nada, se les pone condición de entrada.
3. **Usar los 26 mockups YA FIRMADOS** para el primer bit de realidad esta semana. Coste: 0 días
   de ingeniería. Se le escapó a los 5 asesores; lo cazó un peer review.

## Lo que duele (y es verdad)

- **La fábrica sabe escribir; no sabe equivocarse.** Sin código que devuelva FAIL, 9 documentos
  internamente coherentes y muy citados pueden estar enteramente equivocados sobre el mundo. Las
  citas son autoridad prestada, no evidencia.
- **Andrea firmó 9 decisiones que no puede evaluar** (está aprendiendo Swift). "La arquitectura
  que no puedes depurar no es tu arquitectura; es deuda con cara de activo."
- **La regla "lo aceptado no se re-litiga" se volvió en contra:** nació para proteger del rediseño
  compulsivo; aplicada a 9 hipótesis NO VERIFICADAS, congela como irreversible lo que nunca se
  probó. Arreglo propuesto: estado `provisional` + criterio de falsación.

## Dos preguntas sin auditar (deuda abierta)

1. **¿De dónde sale que el offline es el caso de uso?** Roaming UE, wifi en cada bar. Si el offline
   es opcional, se cae >50% de esta arquitectura (PowerSync, cola, idempotencia, tombstones, CRDTs,
   media matriz STRIDE).
2. **¿Por qué 60 días de retención de idempotencia?** OASIS menciona ~50 días para móviles, pero el
   número exacto se eligió sin justificar bien.

## Bloqueo material que nadie había visto

**Sin cuenta Apple Developer (99 €/año) no hay TestFlight** → ningún consejo de "enséñasela a tu
squad" es ejecutable más allá de los móviles físicamente presentes. Es la decisión más urgente, y
no es técnica.

---

## Los cinco veredictos completos

### contrarian



**El fallo fatal no está en ningún ADR. Está en que ninguno se rechazó.**

Nueve decisiones, nueve aceptadas, firmadas de golpe con un "firma los ADRs y mergea todo". Eso no es un gate humano-en-el-bucle: es un sello de goma. Andrea está aprendiendo Swift y acaba de firmar dedupe estructural, HLC como metadato, fractional indexing y una matriz de 11 capabilities que no puede evaluar. Y la constitution dice que las decisiones aceptadas **no se re-litigan**. Has convertido en irreversible lo que nunca fue verificado.

Lo que MiniMax encontró no es una anécdota, es el diagnóstico. Las contradicciones viven **entre** documentos, y crecen cuadráticamente: 9 ADRs = 36 pares. La fábrica sabe producir documentos; no sabe falsarlos, porque no hay código que devuelva un `FAIL`. Cuatro días de movimiento perpetuo documental sin un solo bit de realidad en contra.

Tres apuestas concretas que nadie ha probado y que la firma ya dio por buenas:

1. **Un backend Swift como único escritor + PowerSync.** PowerSync existe para sincronizar contra Postgres. Meter un servicio propio delante obliga a traducir `getCrudBatch()` a POSTs de dominio a mano, síncronos contra la BD. ¿Dónde corre ese servicio Swift a 0 €? Si la respuesta es "el Pi", el Pi ya es infraestructura crítica (ping nocturno, backups) y punto único de fallo de una operación de una persona.
2. **`MiembroId` en vez de `UsuarioId` en todos los agregados.** RGPD elegante, y una indirección extra en cada lectura del bento, escrita antes de saber si el bento rinde.
3. **Seis dominios en v1.** El coste real no es la arquitectura: es que ninguna de estas 9 decisiones se ha estrellado todavía contra un usuario.

Los cimientos no están mal calculados. Están calculados **para un edificio que aún no sabes si alguien quiere habitar** — y firmados a ciegas.

### firstprinciples



Estáis preguntando lo que no toca. "¿Están bien calculados los cimientos?" solo tiene respuesta si existe el edificio. Andrea está echando hormigón en un descampado. Técnicamente el hormigón es excelente —lo digo en serio: el análisis de NP-completitud del *settle*, el 200-OK-en-vez-de-4xx para no bloquear la cola de PowerSync, `MiembroId` en vez de `UsuarioId` para que el fantasma RGPD salga barato— eso es trabajo de un ingeniero senior. Y da igual, porque **la pregunta real es: ¿por qué cuatro días de fábrica no han producido ni una sola prueba de que alguien quiera esta app?**

Reformulemos el problema. El proyecto murió una vez. El diagnóstico fue "rediseñaba a mitad de código", y la cura fue "diseñar más antes de codificar". Ese diagnóstico es falso. Rediseñaba a mitad de código **porque no sabía qué construía ni para quién** — no tenía nada externo contra lo que contrastar. Nueve ADRs no arreglan eso: son la misma enfermedad con mejor traje. Antes evitaba enviar rediseñando; ahora evita enviar documentando. En ambos casos: cero contacto con la realidad.

Y hay una decisión enterrada que nadie ha auditado: **el offline-first**. De ahí cuelga PowerSync, la cola, la idempotencia de 60 días, los tombstones, los CRDTs y media matriz STRIDE. ¿De dónde sale que el offline es el caso de uso? De una frase ("los viajes ocurren sin cobertura"), no de un usuario. Roaming gratis en la UE, wifi en cada bar. Si el offline es opcional, se cae el 60 % de esta arquitectura de golpe.

Salvad las tres decisiones baratas-hoy/caras-mañana (`Int64` en céntimos, `MiembroId`, indexación fraccional). El resto, a `docs/parked/`. Y en dos semanas, que cinco squads de verdad hayan usado *algo*.

Los cimientos no están mal calculados. Están calculados para un edificio que nadie ha pedido.

### expansionist



**Lo infravalorado no es la app. Es la fábrica.**

Andrea cree que ha hecho arquitectura. Lo que en realidad ha construido es **un método reproducible para que una sola persona produzca decisiones de nivel senior con trazabilidad forense** — y ese es el activo con más upside de todo el dossier. Los 9 ADRs son el *output*; la máquina que los escupe es el *producto*.

Mira lo que ya funciona: MiniMax detectó dos contradicciones **entre documentos** (el 412 en la cola contra el §4 de PowerSync). Codex predijo el bug del expulsado **antes de que existiera código**. Eso no es "revisión con IA": es un sistema de detección de contradicciones cruzadas que la mayoría de equipos con 20 ingenieros no tiene. Y cada afirmación va anclada a IAS 21, ASVS 8.3.2, Vernon, el draft del IETF. Eso es un **corpus auditable**, no una opinión.

Tres upsides que nadie está contando:

1. **Los ADRs son el mejor contexto de agente que existe.** Cuando empiece el código, esos 9 documentos + el glosario vinculante + las 18 invariantes funcionan como *prompt de sistema*: hacen que los agentes escriban Swift casi correcto a la primera. Los 4 días no son coste hundido — son el multiplicador de las próximas 400 horas.

2. **El motor de saldos es un producto separable.** Servicio de dominio puro, sin BD, 18 invariantes property-testeadas, `Int64`, largest remainder, FX congelado por IAS 21. Eso es un paquete Swift open-source. Y es lo que le da autoridad pública antes de tener un solo usuario.

3. **La fábrica es su portfolio, no la app.** Es estudiante, freelance, 0 €. TripSquad puede fracasar; "monté una fábrica multi-agente que produce arquitectura auditada, y la documenté en abierto" no fracasa. Es el contenido, la carta de presentación y el siguiente contrato.

**El riesgo real no es la sobre-ingeniería. Es que envíe el barco y tire la fábrica al mar.** Documéntala mientras la usas.

### outsider



Vale, voy a decir lo que veo, sin filtro.

Nueve documentos de arquitectura. Cero líneas de código. Cero usuarios. Una persona. Eso, visto desde fuera, no parece ingeniería: parece **miedo con formato profesional**. Documentar es la única actividad que se siente productiva y no puede fallar nunca. El código sí puede fallar. Y llevas cuatro días eligiendo la actividad que no puede fallar.

Cosas que me hacen decir "¿perdona?":

**Un modelo de amenazas con una matriz de 11 filas.** ¿Amenazas de quién? Son seis amigos decidiendo si van a Lisboa. El atacante es Javi, que quiere que le devuelvas los 40€ de la cena. Nadie está atacando tu app: nadie la conoce.

**Anonimización GDPR de usuarios fantasma.** No tienes usuarios. No puedes violar la privacidad de un conjunto vacío.

**Relojes lógicos híbridos y CRDTs para resolución de conflictos.** ¿Cuánta gente edita el mismo campo del mismo viaje en el mismo segundo, sin conexión, siendo seis amigos? La respuesta honesta es: casi nunca. Y cuando pase, la solución que un humano normal acepta es "gana el último" o "mira, lo cambió Marta".

**Motor de liquidación de deudas, NP-completo, 18 invariantes.** Splitwise resuelve esto con una división y una resta. Nadie ha pedido jamás el número óptimo de transferencias. Han pedido saber a quién le deben cuánto.

**Claves de idempotencia con retención de 60 días.** ¿Por qué 60? ¿De dónde sale ese número? Sospecho que de ningún sitio.

Lo que veo bien: las decisiones de cliente (iOS primero, contrato OpenAPI) son reales y baratas de revertir. Eso sí sirve.

Mi lectura: no son cimientos mal calculados. Son cimientos **para un edificio distinto** — uno con millones de usuarios que aún no existe. Y unos cimientos para un edificio que no vas a construir no son cimientos: son un foso.

Escribe la pantalla de gastos. Esta semana. Fea. Enséñasela a cuatro amigos y que te digan que está mal. Ahí empieza la información real.

### executor



**Los ADRs no están mal razonados. Están mal *secuenciados*.**

**Qué hace falta para ver UN gasto en pantalla:** el motor de saldos (Int64, largest
remainder, netos+greedy) es Swift puro sin BD. Son ~300 líneas. Con SwiftData local y
la UI del diseño v7 ya cerrado, Andrea tiene un divisor de gastos funcionando en su
iPhone **esta semana**. ADRs implicados: 2 (0010 modelo, 0011 motor). Los otros 7:
**cero**.

**Qué exige en cambio el "slice vertical" tal como está escrito.** Cuenta conmigo:
contrato OpenAPI + generador en CI · backend Swift (Hummingbird/Vapor, framework *aún
sin decidir*) desplegado en Linux · esquema Postgres + RLS + funciones SECURITY DEFINER
· PowerSync + sync rules + test de paridad · tabla de idempotencia + reaper +
`write_rejections` + **una pantalla nueva de "rechazado"** · ETag/If-Match en todos los
verbos · outbox · retry+circuit breaker · los 3 tests E2E de STRIDE *antes de la primera
feature*. Son **cinco sistemas distintos** que solo fallan cuando interactúan. Para
alguien que está aprendiendo Swift —y que ahora tendría que aprender *server-side* Swift
a la vez— eso no es un slice: son 8–12 semanas antes del primer usuario, y el primer bug
será indepurable porque no sabrás en cuál de los cinco vive.

**Camino más corto, mismo destino:**

1. **Semana 1:** motor de saldos + property tests. Es el único sitio donde el rigor ya se paga.
2. **Semanas 2–3:** app iOS mono-dispositivo, datos locales. Enséñasela a tu squad. Ahí descubres si el producto vale algo.
3. **Después:** Supabase directo con RLS (sin backend Swift propio). Multi-dispositivo real.
4. **Solo cuando duela:** PowerSync, idempotencia, outbox.

Los ADRs ya inventaron la herramienta que les falta: **criterio de activación**
(ADR-0013 lo hace con los CRDTs). Aplícalo a los otros ocho. No borres nada; **ponles
fecha de activación**. Lo irreversible —`MiembroId` no `UsuarioId`, `Int64` no `Double`,
UUID de cliente, fractional indexing— entra en el esquema hoy, gratis. Lo demás es
infraestructura para un tráfico que aún no existe.

---

## Peer reviews anónimos

# Peer review — Consejo LLM (revisor 1)

## 1. La más fuerte: **A**

Es la única que separa *mérito* de *secuencia*. No dice "tira los ADRs" (C, D) ni "abrázalos"
(B): dice que están bien razonados y **mal ordenados**, y lo demuestra contando el coste real
del "slice vertical" tal como está escrito — cinco sistemas acoplados (contrato+CI, backend
Swift *aún sin framework decidido*, Postgres+RLS, PowerSync, idempotencia/outbox) que solo
fallan cuando interactúan, para alguien que además tendría que aprender server-side Swift a la
vez.

Y aporta la única herramienta reutilizable del dossier: **criterio de activación** — que ella
misma ya inventó en ADR-0013 para los CRDTs — aplicado ahora a los otros ocho ADRs. Salva el
trabajo hecho, desbloquea el envío y no pide fe. Además distingue correctamente lo
irreversible-y-gratis-hoy (`Int64` en céntimos, `MiembroId`, UUID de cliente, fractional
indexing) de la infraestructura para un tráfico que no existe.

C y D son retóricamente brillantes y su diagnóstico psicológico es probablemente correcto
("miedo con formato profesional"), pero ambas acaban en el mismo consejo genérico — "envía algo
esta semana" — sin decir *qué se conserva y bajo qué condición se activa el resto*. A sí lo dice.

## 2. Mayor punto ciego: **B**

B confunde **volumen de trazabilidad con validación**. Que MiniMax detecte contradicciones entre
documentos no prueba que los documentos sean *ciertos*: prueba que son *mutuamente consistentes*.
Una fábrica sin código que devuelva `FAIL` puede producir un corpus internamente coherente,
citado hasta las cejas (IAS 21, ASVS, Vernon, drafts del IETF) y enteramente equivocado sobre el
mundo real. Las citas son autoridad prestada, no evidencia.

Peor: B propone **doblar la apuesta en la actividad que ya mató el proyecto una vez**, ahora con
branding de "portfolio" y "activo con más upside". Es la respuesta que Andrea *quiere* oír, y por
eso es la más peligrosa. Su argumento de que los ADRs son "el mejor contexto de agente que
existe" también es dudoso: 9 documentos con 36 pares posibles de contradicción (como señala E)
son tanto un multiplicador de errores como de aciertos cuando se usan de prompt de sistema.

## 3. Lo que se les escapó a TODAS

**Nadie pregunta si Andrea entiende lo que firmó.**

Está aprendiendo Swift y ha aceptado dedupe estructural, relojes lógicos híbridos, fractional
indexing, RLS con funciones SECURITY DEFINER y una matriz de 11 capabilities. E roza el tema
("firmados a ciegas") pero lo trata como un fallo de *gobernanza* (el gate humano fue un sello de
goma), no como lo que realmente es: un fallo de **propiedad del conocimiento**.

La consecuencia práctica que ninguna respuesta nombra: al primer bug, unos ADRs que ella no puede
leer con criterio no se respetan — **se ignoran**. Y ahí vuelve exactamente el fallo original
(rediseñar a mitad de código), solo que ahora con nueve documentos muertos en `docs/` acusándola.
La arquitectura que no puedes depurar no es tu arquitectura; es deuda con cara de activo.

Corolario, también ausente en las cinco: **el test barato y obvio no se hizo**. Una noche
enseñando la idea (o un boceto en papel) a su propio squad — el squad con el que viaja — habría
producido más información sobre qué construir que los cuatro días completos de fábrica. Coste:
cero euros, dos horas. Nadie lo propuso como *el siguiente paso literal*.

# Peer review — Consejo LLM (revisor 2)

## 1. La más fuerte: **A**

Es la única que separa lo *irreversible-barato-hoy* (`Int64` en céntimos, `MiembroId`,
UUID de cliente, fractional indexing) de lo *infraestructural-caro-mañana*, y en vez de
tirar el trabajo le aplica una herramienta que la propia fábrica ya inventó: **criterio de
activación** (ADR-0013, CRDTs). Da un camino concreto y ejecutable (motor de saldos →
app iOS local → Supabase directo con RLS → PowerSync solo cuando duela) y cuantifica el
coste real del "slice vertical" tal como está escrito: cinco sistemas acoplados
(contrato+CI, backend Swift en Linux, Postgres+RLS, PowerSync, idempotencia/outbox) que
solo fallan cuando interactúan — indepurables para alguien que además tendría que aprender
server-side Swift a la vez.

C y D dicen algo parecido pero con brocha gorda. **D es injustamente despectiva**:
"Splitwise resuelve esto con una división y una resta" es falso, y descarta el motor de
saldos, que es justo la pieza donde el rigor sí se paga y donde las decisiones (céntimos en
`Int64`, largest remainder, FX congelado) sí son caras de revertir una vez hay datos reales.
C acierta al auditar la decisión enterrada (offline-first como raíz de la mitad de la
arquitectura), pero se queda en el diagnóstico sin dar la palanca de cambio.

## 2. El punto ciego más grande: **B**

Está **seducida por la elegancia**. Convierte el proceso en producto ("lo infravalorado es
la fábrica") y **jamás pregunta si los ADRs son correctos**.

Peor: usa como prueba de calidad que MiniMax detectó contradicciones entre documentos y que
Codex predijo el bug del expulsado. Eso no es evidencia de rigor — es una **tasa de defectos**
medida sobre documentos que nadie puede falsar, porque no hay código que devuelva `FAIL`.

Y su tesis estrella — "los 9 ADRs son el mejor contexto de agente que existe, el multiplicador
de las próximas 400 horas" — solo se sostiene **si los ADRs son ciertos**. Si están mal
calibrados, ese "prompt de sistema" no multiplica: propaga el error a máxima velocidad y con
autoridad documental. B toma el riesgo central del dossier (arquitectura no verificada) y lo
reetiqueta como activo.

## 3. Lo que se le escapó a TODAS

**a) El bug está en la constitution, no en los ADRs.**
Ninguna respuesta ataca la regla de proceso que causa el daño: *"las decisiones aceptadas no
se re-litigan"*. Eso convierte 9 hipótesis no verificadas en dogma. Ningún ADR tiene **estado
provisional** ni **criterio de falsación** ("este ADR se considera refutado si X"). E roza el
problema ("firmados a ciegas") pero no propone el arreglo. Y el arreglo es barato y compatible
con append-only: **ADR-0014 que introduce el estado `provisional` + criterio de activación y
de falsación para los 8 ADRs de infraestructura**. No se borra nada; se les pone condición de
entrada. Es la misma medicina que A receta, pero elevada al nivel donde vive la enfermedad.

**b) El bloqueo material que nadie nombró: los 99 €/año de Apple.**
Presupuesto €0. Pero sin cuenta de Apple Developer no hay TestFlight, y sin TestFlight
**ninguno** de los consejos del consejo es ejecutable: "enséñasela a cuatro amigos" (D),
"que cinco squads de verdad usen algo en dos semanas" (C), "enséñasela a tu squad" (A) —
todos asumen distribución que hoy no existe. Se puede hacer con builds ad-hoc por cable/Xcode
a un puñado de dispositivos, pero eso limita el bucle de feedback a quien esté físicamente
cerca. Es la única restricción verdaderamente dura del dossier y los cinco advisors la
ignoraron por completo mientras discutían CRDTs.

**c) Corolario práctico:** la primera decisión que hay que tomar no es técnica sino de
distribución (99 € o builds a mano), porque determina la velocidad de todo el ciclo de
aprendizaje que los cinco reclaman.

# Peer review — Consejo LLM sobre TripSquad (revisor 3)

## 1. La más fuerte: **A**

Es la única que aplica el bisturí en el sitio correcto: separa **corrección** de **escala**.

- Salva el motor de saldos (Int64, largest remainder, netos+greedy, property tests) como trabajo de la
  semana 1 — porque ahí el rigor *sí* se paga hoy, con seis usuarios o con seis millones.
- Aparca los 7 ADRs de infraestructura (PowerSync, idempotencia, outbox, ETag, STRIDE E2E) sin borrarlos.
- Aporta la herramienta operativa que ninguna otra da: **criterio de activación** — ya inventado por la
  propia fábrica en ADR-0013 para los CRDTs — aplicado a los otros ocho ADRs. No borra nada, no re-litiga:
  es compatible con la constitution ("las decisiones no se re-litigan").
- Es la única que **cuenta el coste real del "slice vertical"** tal como está escrito: cinco sistemas
  distintos que solo fallan cuando interactúan, más Swift server-side que Andrea no sabe. 8–12 semanas y
  un primer bug indepurable.
- Distingue lo irreversible-y-gratis-hoy (`MiembroId` no `UsuarioId`, `Int64` no `Double`, UUID de
  cliente, fractional indexing) de lo caro-y-aplazable. Esa es exactamente la línea correcta.

Camino más corto, mismo destino. Es consejo accionable el lunes por la mañana, no terapia.

**Menciones:** B es la única con una tesis *positiva* (la fábrica es el activo, no la app) y probablemente
tiene razón sobre el portfolio — pero no responde a la pregunta que Andrea hizo. E acierta en el
diagnóstico de gobernanza (nueve ADRs, nueve aceptados, cero rechazados = sello de goma) pero se queda
en el meta-nivel. C escribe la mejor frase del dossier ("calculados para un edificio que nadie ha pedido")
y hace la mejor pregunta enterrada (**¿de dónde sale que el offline es el caso de uso?** — roaming UE,
wifi en cada bar; si el offline es opcional se cae el 60% de la arquitectura). Esa pregunta debería
sobrevivir a este consejo aunque C no gane.

---

## 2. El punto ciego más grande: **D**

D confunde precisamente lo que no se puede confundir, y lo hace en el sitio donde duele.

> "Motor de liquidación de deudas, NP-completo, 18 invariantes. Splitwise resuelve esto con una división
> y una resta."

Es falso y es peligroso. El reparto de céntimos, el redondeo de un importe indivisible entre 6, los
duplicados por reintento y el FX congelado **no son preparación para escala**: son la definición de que
la app funciona. Si seis amigos parten 985 € y la app pierde un céntimo o duplica un gasto, el squad
desinstala el día uno — con cero usuarios previos y con un millón. D trata la corrección monetaria como
si fuera sobre-ingeniería para tráfico futuro.

Y el consejo literal de D ("escribe la pantalla de gastos, esta semana, fea") sin el motor detrás
produce exactamente el fracaso que dice querer evitar: un divisor que pierde céntimos, enseñado a cuatro
amigos que dejan de confiar en él. La prueba de realidad se contamina.

Lo demás de D está bien y hay que quedárselo: el STRIDE de 11 filas contra "Javi, que quiere sus 40 €";
el RGPD sobre el conjunto vacío; los CRDT para conflictos que casi nunca ocurren; y el mejor detalle
forense del dossier — **"¿Por qué 60 días de idempotencia? Sospecho que de ningún sitio"**. Ese es el
tipo de número que la fábrica escupe con autoridad falsa y nadie audita.

C comete media versión del mismo error (manda "el resto" a `docs/parked/`) pero se salva porque salva
explícitamente `Int64` en céntimos. D no salva nada del motor.

---

## 3. Lo que se les escapó a TODAS

### (a) El diseño ya terminado es el vehículo de falsación, y nadie lo usó

Las cinco respuestas plantean la falsación como una dicotomía **docs vs. código**: "escribe la pantalla",
"que cinco squads usen algo", "cero bits de realidad en contra". Ninguna se dio cuenta de que
**existen 26 pantallas diseñadas y firmadas, con la UI de gastos incluida**.

El test de realidad más barato del proyecto **cuesta cero días de ingeniería**: enseñar los mockups de
gastos a tres squads reales esta semana — un prototipo clicable, o literalmente el PDF — y ver si alguien
dice "esto lo usaría en Lisboa". Eso corre **en paralelo** al motor de saldos, no en competencia con él.

C y D exigen contacto con la realidad y no ven que el vehículo ya está construido y pagado. Es un fallo
de lectura del dossier, y es el que más caro sale: convierte un debate de 8 semanas en un experimento
de 3 días.

### (b) Las 18 invariantes no son corrección: son una *promesa* de corrección

Nadie lo dijo con claridad. Un property test escrito en un ADR es prosa. Hasta que exista un runner que
devuelva `FAIL`, las 9 decisiones son **afirmaciones no falsadas** — bien razonadas, ancladas a IAS 21 y
ASVS, y sin un solo bit de realidad en contra. E roza esto ("la fábrica sabe producir documentos; no sabe
falsarlos") pero lo enmarca como problema de gobernanza. Es peor que eso: es epistemológico. **La fábrica
sabe escribir; no sabe equivocarse.**

Y encima la constitution dice que lo aceptado no se re-litiga. Se está congelando como irreversible lo
que nunca fue verificado. La regla "no re-litigar" fue diseñada para proteger decisiones *probadas*
contra el rediseño compulsivo; aplicada a nueve decisiones no probadas, es la misma enfermedad con
mejor traje.

### (c) El diagnóstico original nunca se auditó

"El proyecto murió porque rediseñaba a mitad de código" → cura: "diseñar más antes de codificar".
Solo C ataca esto, y de pasada. Pero es la raíz: si la causa real fue *no tener nada externo contra lo
que contrastar*, entonces la cura adoptada **amplifica la enfermedad**. Antes evitaba enviar
rediseñando; ahora evita enviar documentando. Nueve ADRs en cuatro días es el mismo bucle a mayor
velocidad. Ninguna respuesta propone el único antídoto real: **una fuente de verdad externa** (usuarios,
o un test que falle) que no sea otro documento firmado por ella misma.

---

## Juicio directo sobre la pregunta del brief

**Sí, hubo confusión — y fue D quien la cometió de forma pura.**

Hay dos cosas distintas que el consejo mezcla:

| | Construir para **escala** (prematuro) | Construir para **corrección** (no prematuro) |
|---|---|---|
| Ejemplos en este dossier | PowerSync, outbox, ETag/If-Match, matriz STRIDE de 11 capabilities, CRDTs, HLC, retención de 60 días, backend Swift como único escritor | Motor de saldos: `Int64` en céntimos, largest remainder, no-pérdida-de-céntimo, dedupe estructural, FX congelado, `MiembroId` |
| Qué pasa si lo omites hoy | Nada. Lo añades cuando duela. | La app miente sobre el dinero de tus amigos. Fin. |
| Qué pasa si lo haces hoy | 8–12 semanas sin usuarios. | ~300 líneas de Swift puro, sin BD. Una semana. |

- **A** hace esta distinción explícitamente y construye su recomendación sobre ella. Por eso gana.
- **C** la hace a medias: manda casi todo a `parked/` pero rescata `Int64` en céntimos, `MiembroId` e
  indexación fraccional — es decir, intuye la línea aunque no la nombre.
- **E** no la hace: mete `MiembroId` en su lista de "apuestas no probadas" cuando es exactamente el tipo
  de decisión barata-hoy/carísima-mañana que hay que tomar antes de tener un esquema.
- **B** no la hace, pero por el otro lado: defiende el motor de saldos por su valor de *portfolio*
  (paquete open-source, autoridad pública), no por su valor de corrección. Buen argumento, razón
  equivocada.
- **D** la invierte: es la más lúcida sobre lo que sobra (STRIDE, RGPD, CRDT, los 60 días) y la más ciega
  sobre lo que no sobra (el motor). Le pega al blanco correcto con la munición equivocada.

**Conclusión operativa:** el veredicto para Andrea no es "está bien" ni "está mal". Es
**"está bien razonado y mal secuenciado"** (A), con una corrección importante que a A también se le
escapó: el experimento más barato disponible no es escribir código, es **usar los 26 mockups que ya
tienes** para conseguir el primer bit de realidad esta semana. Motor de saldos + mockups a squads
reales, en paralelo. Los otros siete ADRs: fecha de activación, no papelera.

