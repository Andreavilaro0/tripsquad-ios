# ADR-0010 — Modelo de dominio: contextos, agregados y usuario fantasma

- **Fecha:** 2026-07-14
- **Estado:** proposed
- **Dueña:** Andrea
- **Origen:** bead R2 (`TripSquad-iOS-6g8`), design doc Backend F3
- **Depende de:** ADR-0009 (monolito modular + Clean Architecture)

## Contexto

ADR-0009 fijó la estructura (monolito modular, un módulo por frontera) pero dejó
la lista de módulos como **hipótesis a validar**: Expenses, Membership,
Itinerary, Voting, Chat, Media. R2 la valida contra DDD (Evans/Vernon, Fowler,
guía de Microsoft) y define agregados, lenguaje ubicuo, consistencia y el diseño
del usuario fantasma (RGPD). El glosario que aquí se fija es el mismo que usarán
código, contrato OpenAPI y UI.

## Decisión

### 1. Contextos delimitados — la hipótesis era correcta pero **incompleta**

Se añaden tres contextos que estaban implícitos y contaminaban a los demás:

| Contexto | Tipo | Frontera |
|---|---|---|
| **Gastos y Liquidación** | **CORE** | El dinero. Invariantes duras. Aquí va el rigor (property-tests, R3). |
| **Squad y Membresía** | **CORE** | Ciclo de vida del viaje y del acceso: invitar, expulsar, salir, cerrar. |
| **Acceso** *(nuevo)* | **CORE-supporting** | Traduce "es miembro activo" → *capabilities* concretas (token realtime, URL firmada, topic push, bucket offline, contexto IA). |
| **Identidad y Privacidad** *(nuevo)* | Generic + regla propia | Cuenta global de usuario y anonimización RGPD. Separa `Usuario` de `Miembro`. |
| **Itinerario** | Supporting | Modelo temporal/jerárquico con reglas propias (solape, orden). |
| **Votaciones** | Supporting | Recuento y cierre. Reglas simples y aisladas. |
| **Conversación (Chat)** | Generic | Mensajería es problema resuelto: se usa la infra del BaaS. |
| **Media / Recuerdos** | Generic-supporting | La complejidad es de infra (buckets, caducidad), no de dominio. |
| **Brújula IA** *(nuevo)* | Supporting | **Consumidor** de los demás vía proyección de lectura con anti-corruption layer; nunca escribe en otros contextos salvo por sus casos de uso. |

**Por qué "Acceso" es un contexto y no un `if`:** sin él, revocar el acceso de un
expulsado es una condición dispersa por seis módulos — exactamente el bug de
privacidad que Codex predijo. Como contexto, la revocación es **una rutina
cerrada y testeada**: `revocarTodo(miembro)` cubre canal realtime, URLs firmadas,
push, bucket offline y contexto IA. **Toda capability nueva se registra en esa
rutina o el PR no se mergea.**

El rigor de modelado se gasta en los CORE. Chat y Media pueden ser CRUD sin culpa.

### 2. Agregados — el Viaje **no** es un agregado gigante

Reglas de Vernon adoptadas: invariantes verdaderas dentro de la frontera de
consistencia · agregados pequeños · referencias a otros agregados **por ID, nunca
por objeto** · **una transacción = un agregado**.

- **Viaje** (raíz, Membresía) — pequeño: `id, nombre, fechas, divisaBase, estado
  (planificando|activo|cerrado), miembros[]`. Invariantes: ≥1 organizador; un
  viaje cerrado no admite escrituras de dominio. Un `Viaje` que contuviera chat +
  itinerario + gastos + fotos sería el anti-patrón *large-cluster*: cada mensaje
  chocaría con cada gasto.
- **Membresía** — entidad hija de Viaje, **no** agregado propio: sus invariantes
  ("no dos membresías activas del mismo usuario", "no expulsar al último
  organizador") necesitan la lista completa delante.
- **Concesión de Acceso** (raíz, Acceso) — **sí** agregado propio: su ciclo de
  vida es técnico (emitir/revocar token, URL firmada, suscripción push) y cambia
  a otro ritmo que la membresía.
- **Gasto** (raíz, Gastos) — `id, viajeId, pagadorId, importe (Dinero), fecha,
  reparto[]`. Invariante: **la suma de las cuotas es igual al importe total**
  (con política de redondeo explícita; el resto va al pagador — R3 lo fija).
  `Dinero` = value object (entero en unidades menores + divisa). **`Double`
  prohibido.**
- **Liquidación** (raíz, Gastos) — fotografía inmutable de los pagos mínimos
  propuestos en un instante, con estado por pago (propuesto|marcadoPagado|
  confirmado). **Los saldos NO se almacenan**: son una proyección derivada de
  Gastos + Pagos, y suman cero siempre.
- **Actividad** (raíz, Itinerario) — no `Día`: el día es un agrupador de lectura.
  Invariante: cae dentro del rango de fechas del viaje. Fechas civiles, no
  instantes (guía de contrato §8).
- **Votación** (raíz) — un voto por miembro y opción; cerrada = inmutable.
- **Mensaje**, **Foto** — raíces diminutas, append-only, sin invariantes cruzadas.

### 3. Lenguaje ubicuo (español)

Vinculante: el mismo término en dominio, contrato y UI.

**Viaje** (unidad raíz; *planificando/activo/cerrado*) · **Squad** (los miembros
activos; término de UI, en código `miembrosActivos`) · **Miembro** (participación
de un Usuario en un Viaje, con rol y estado *activo/salido/expulsado* — dentro de
un viaje **nunca** se dice "usuario") · **Usuario** (cuenta global, existe sin
viajes) · **Organizador** (rol que invita, expulsa y cierra) · **Invitación**
(derecho de entrada con caducidad) · **Gasto** (dinero que un *pagador* adelantó
por cuenta de varios) · **Reparto** (cómo se divide) · **Dinero** (importe +
divisa; value object) · **Saldo** (lo que se debe *ahora*; derivado, nunca
escrito a mano) · **Liquidación** (plan de pagos mínimos que lleva los saldos a
cero) · **Pago** (transferencia real; es un hecho, no una promesa) ·
**Actividad** · **Itinerario** · **Votación** · **Mensaje** · **Foto** ·
**Recuerdo** (viaje cerrado, solo lectura) · **Sello** (insignia que un viaje
cerrado deja en el perfil) · **Brújula** (asistente IA; responde solo con lo que
ese miembro puede ver) · **Cierre** · **Expulsión / Salida** (ambas ⇒ revocación
de acceso) · **Fantasma** (miembro anonimizado: sus cifras siguen, su identidad
no).

### 4. Consistencia y eventos de dominio

- **Transaccional** (dentro de un agregado): cuotas == importe del gasto;
  miembros y roles del viaje; votos de una votación; estado de un pago.
- **Eventual** (entre agregados, vía eventos): saldos tras un gasto; revocación
  de acceso tras expulsión; cierre en cascada; contexto de la Brújula.
- Regla operativa: **1 comando = 1 transacción = 1 agregado**; el resto lo mueve
  un manejador de evento **idempotente** (encaja con los IDs de cliente y las
  escrituras idempotentes ya decididas: reintentar es seguro y el offline cuadra).
- Eventos (en pasado): `ViajeCreado`, `MiembroInvitado`, `MiembroUnido`,
  `MiembroSalió`, `MiembroExpulsado`, `RolCambiado`, `ViajeCerrado`,
  `GastoRegistrado`, `GastoEditado`, `GastoEliminado`, `LiquidaciónGenerada`,
  `PagoMarcado`, `PagoConfirmado`, `ActividadAñadida`, `ActividadMovida`,
  `VotaciónAbierta`, `VotoEmitido`, `VotaciónCerrada`, `MensajeEnviado`,
  `FotoSubida`, `AccesoRevocado`, `UsuarioAnonimizado`.
- Evento crítico: `MiembroExpulsado`/`MiembroSalió` → Acceso ejecuta
  `revocarTodo(miembro)`. Con test de contrato propio (R6).

### 5. Usuario fantasma (RGPD)

Base legal: el Art. 17 no es absoluto (cabe conservar lo necesario para
obligaciones legales y defensa de reclamaciones) y el Considerando 26 deja los
datos **anónimos** fuera del RGPD — los seudonimizados **no**. Por tanto:
**anonimizar de verdad, no seudonimizar.**

- **Se borra:** email, teléfono, nombre real, avatar (y derivados), tokens push,
  dispositivos, logs con PII, embeddings del contexto IA con su texto.
- **Se sustituye:** nombre mostrado → "Miembro eliminado"; avatar → placeholder.
- **Se conserva:** importes, repartos, pagos y su `UsuarioId` (clave técnica sin
  significado) — **los saldos de terceros son datos de terceros** y la suma debe
  seguir dando cero.
- **Invariante que lo hace barato:** ningún agregado guarda nombre ni avatar
  copiados; solo `UsuarioId`. El nombre se resuelve en la capa de lectura contra
  Identidad. Así, anonimizar es **un solo UPDATE**, no una migración por seis
  módulos. **Denormalizar el nombre "por rendimiento" rompe el fantasma: queda
  prohibido.**
- Evento `UsuarioAnonimizado` invalida cachés, proyecciones y contexto IA.

### 6. Qué de DDD NO se usa

- **Event sourcing: no.** El estado actual es la fuente de verdad; los eventos son
  notificaciones. El coste (proyecciones, versionado, replay) no lo paga ninguna
  auditoría regulada aquí, y un log inmutable de eventos hace la anonimización
  RGPD un infierno.
- **CQRS completo (dos bases, buses): no.** Sí la versión barata: modelos de
  lectura distintos de los agregados (los saldos son una proyección), en la misma
  base de datos.
- **Un servicio por contexto: no.** Ya decidido en ADR-0009: contexto = módulo con
  frontera de compilación. Partir antes de que duela es pagar coordinación
  distribuida sin equipo distribuido.
- **Modelo rico donde el dominio no lo pide: no.** Chat y Media pueden ser CRUD.

## Alternativas consideradas

- **Mantener la lista de 6 módulos de ADR-0009 tal cual** — deja Acceso e Identidad
  implícitos; es el camino directo al bug del expulsado-que-ve y a un fantasma
  imposible de implementar sin migración masiva. Descartada.
- **Viaje como agregado raíz de todo** — modelo "natural" para el bento de la UI,
  pero es el anti-patrón large-cluster: contención, cargas caras y conflictos de
  concurrencia entre mensajes y gastos. Descartada.
- **Saldos almacenados y actualizados en cada gasto** — más rápido de leer, pero
  crea una segunda fuente de verdad del dinero que puede divergir. Se prefiere la
  proyección derivada (y cachearla si el rendimiento lo pide).

## Consecuencias

- La lista de módulos de ADR-0009 se amplía a **nueve contextos**: los seis
  originales + Acceso + Identidad + Brújula.
- R3 (motor de saldos) trabaja sobre `Gasto`/`Liquidación` con `Dinero` como value
  object y la invariante de reparto ya fijada aquí.
- R6 (STRIDE) hereda `revocarTodo(miembro)` como requisito de primera clase, con
  la lista cerrada de capabilities y su test de contrato.
- El glosario es vinculante: el contrato OpenAPI y la UI usan estos términos.
- Coste aceptado: la prohibición de denormalizar nombres puede exigir un join o
  una proyección extra en las lecturas. Es el precio del fantasma barato.

## Pendiente de firma de Andrea (decisiones de producto, no técnicas)

1. **¿El cierre de un viaje es reversible?** (¿puede el organizador reabrirlo?)
2. **¿Se puede cerrar un viaje con saldos abiertos**, o hay que liquidar antes?
3. **Fotos subidas por un usuario anonimizado**: ¿se borran o pasan al viaje?
   Debe decidirse **y escribirse en el aviso de privacidad antes de codificar**.
4. **"Sello"**: si la UI no va a usar ese término tal cual, se renombra o se saca
   del modelo — el lenguaje ubicuo no admite sinónimos.

## Fuentes

- Fowler — *BoundedContext*: https://martinfowler.com/bliki/BoundedContext.html · *DDD_Aggregate*: https://martinfowler.com/bliki/DDD_Aggregate.html · *UbiquitousLanguage*: https://martinfowler.com/bliki/UbiquitousLanguage.html · *CQRS*: https://martinfowler.com/bliki/CQRS.html · *Domain Event*: https://martinfowler.com/eaaDev/DomainEvent.html
- Vernon — *Effective Aggregate Design* I y II: https://dddcommunity.org/wp-content/uploads/files/pdf_articles/Vernon_2011_1.pdf · https://dddcommunity.org/wp-content/uploads/files/pdf_articles/Vernon_2011_2.pdf
- Microsoft Learn — *Designing a microservice domain model*: https://learn.microsoft.com/en-us/dotnet/architecture/microservices/microservice-ddd-cqrs-patterns/microservice-domain-model · *Use domain analysis to model microservices*: https://learn.microsoft.com/en-us/azure/architecture/microservices/model/domain-analysis
- RGPD — Art. 17: https://gdpr-info.eu/art-17-gdpr/ · Considerando 26: https://gdpr-info.eu/recitals/no-26/
