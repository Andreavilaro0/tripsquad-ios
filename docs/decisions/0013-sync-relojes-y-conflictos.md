# ADR-0013 — Sincronización: relojes, conflictos y criterio de CRDT

- **Fecha:** 2026-07-14
- **Estado:** proposed
- **Dueña:** Andrea
- **Origen:** bead R5 (`TripSquad-iOS-ewo`), design doc Backend F3
- **Depende de:** ADR-0012 (cola de escrituras), guía de contrato §6 (ETag/If-Match)

## Contexto

Los viajes ocurren sin cobertura: el offline no es un extra, es el caso de uso. El
design doc dejó abierta **la decisión del reloj** para resolver conflictos
(server-receive-time vs HLC), el criterio de activación de CRDTs, y la paridad
entre las RLS de Postgres y las sync rules de PowerSync (dos superficies de
autorización que deben autorizar igual).

## Decisión

### 1. Honestidad: esto **no es local-first**, es offline-first

Contra los 7 ideales de Ink & Switch, cumplimos 2, a medias 2 y fallamos 3: si el
backend muere, la base local queda huérfana (ideal 5); el servidor lee todo en
claro porque lo necesita para liquidar y para la IA (ideal 6); y el servidor puede
rechazar escrituras (ideal 7). En local-first **la copia local es la primaria** y
el servidor es un relé; aquí **el servidor es la verdad y el cliente es una caché
escribible**.

Es la elección correcta para TripSquad — pero **se llama por su nombre en los
docs**: *offline-first con servidor autoritativo*. No se vende "local-first" en el
README.

### 2. ⭐ El árbitro de conflictos NO es un reloj

**Los relojes de cliente mienten**: NTP roto, el usuario cambia la hora a mano,
cruzar husos horarios (¡literalmente nuestro caso de uso!), y días offline separan
el timestamp de la intención del momento en que se aplica. Con LWW puro *"las
escrituras se pierden por clock skew"* — y no previene *lost updates*.

**El punto débil de server-receive-time es exactamente nuestro escenario:** quien
estuvo 5 días sin red sube el día 6, su edición **llega la última, gana, y pisa lo
reciente de otro**. Justo lo que no queremos.

**Decisión — tres piezas, cada una con su papel:**

1. **`server-receive-time` es el orden canónico** (el servicio Swift sella con el
   reloj de Postgres al aplicar). Un solo reloj, monótono, imposible de falsear
   desde el cliente. Encaja con el único-escritor ya decidido.
2. **El árbitro del conflicto es `ETag`/`If-Match` → `412`**, no el reloj. El
   cliente que estuvo offline manda el ETag **que él conocía**; si otro editó
   mientras tanto, recibe **412 y no pisa nada**: se le muestra el conflicto y
   decide. Esto es lo que salva el caso de los 5 días.

   **`If-Match` es obligatorio también en los DELETE.** Un borrado es la mutación
   *más* destructiva, no la menos: sin precondición, un DELETE encolado hace 5 días
   **borraría un gasto que otro miembro editó mientras tanto**, en vez de dar 412.
   La guía de contrato (§5) dice que DELETE es idempotente y que `If-Match` se
   exige en "updates" — **eso deja el agujero abierto y aquí se cierra**:
   - `DELETE` sobre un recurso editable **exige `If-Match`**; si el ETag no coincide
     (alguien lo editó), → **412**, y la usuaria decide si aún quiere borrarlo.
   - Si el recurso **ya no existe**, el reintento sigue devolviendo **204** (la
     idempotencia del borrado se mantiene: reintentar lo ya hecho no es un error).
   - Solo así conviven las dos propiedades: idempotente ante reintentos, **pero no
     ciego ante ediciones concurrentes**.
3. **El HLC del cliente se guarda como metadato, pero NO decide.** Sirve para
   ordenar y explicar ("esto se editó antes que aquello") y para el día que
   adoptemos CRDTs. Nunca para resolver quién gana.

**Vector clocks: descartados** — crecen con el número de dispositivos y aun así no
responden "quién gana"; delegan esa decisión igualmente en la aplicación.

### 3. CRDTs: criterio de activación explícito

**Señal de activación:** cuando **más del 2 % de las escrituras devuelvan 412**, o
cuando aparezca **texto libre coeditado** (notas de itinerario a varias manos).

**Primera entidad que los pedirá: el ITINERARIO** (lista reordenable, editada por
varios a la vez). El chat no los necesita (es *append-only*) y **los gastos no los
quieren**: con dinero, un conflicto explícito es *deseable* — que dos ediciones se
fusionen solas en silencio es peor que preguntar.

**Preparación que hay que hacer HOY (gratis ahora, cara después):**

- **UUIDv7 generado en cliente** como PK (ya decidido).
- **Versionado por CAMPO**, no por fila entera.
- **Tombstones** para borrados (§5).
- **Fractional indexing para el orden del itinerario**, en vez de `position INT`.
  Es lo más barato de hacer hoy y lo más caro de migrar después: con enteros, dos
  reordenaciones concurrentes colisionan siempre.
- **La cola de escrituras es un log de OPERACIONES, no de estados finales.**

### 4. Paridad RLS ↔ sync rules (la trampa de seguridad)

Son **dos motores distintos** que autorizan lo mismo → la deriva está garantizada
si se escriben por separado. Y son asimétricos: **las RLS son la autoridad de la
escritura**; las sync rules **solo controlan lo que baja al dispositivo**. Nadie
obliga a que coincidan — la doc de PowerSync solo sugiere "generally mirror your
RLS setup".

- **Una sola fuente de verdad: la tabla `trip_members`.** Tanto la función
  `is_member()` de las RLS como la *parameter query* de PowerSync salen de ella.
- **Los parámetros de los buckets salen SOLO del JWT.** La doc de PowerSync avisa
  de que los *client parameters* **no son de confianza** y no deben usarse para
  control de acceso.
- **Test de paridad obligatorio en CI:** fixture con 3 usuarios y 2 viajes (miembro,
  expulsado, extraño); comparar el conjunto de filas visibles **bajo RLS** con el
  conjunto materializado **en la SQLite del cliente**. Deben ser idénticos:
  cualquier fila en la caché local que las RLS no devolverían es un **fallo de
  seguridad**. Cuidado con el detalle que cuesta una fuga: si el `left_at is null`
  está en una superficie y no en la otra, **el expulsado sigue sincronizando**.

### 5. Tombstones y borrado (y su choque con el RGPD)

**Sin tombstone, un cliente offline RESUCITA las filas borradas** al sincronizar.
Pero un tombstone que conserve datos personales choca con el derecho al olvido.

**Decisión:** *tombstone estructural sin datos personales* — se conserva
`{id, deleted_at}` (lo justo para que el borrado se propague) y se hace **hard
delete del contenido**. Si en el futuro escalan las fotos o la ubicación, se
adopta *crypto-shredding* (borrar la clave en vez del dato), reconocido por las
Guidelines 5/2019 del EDPB. **El soft-delete a secas no cumple el Art. 17.**

### 6. PowerSync: Cloud, no self-host

Free tier de PowerSync Cloud (2 GB de sync/mes) + Supabase Free para empezar;
~70 $/mes cuando haya producción temprana (PowerSync Pro 49 $ + Supabase Pro 25 $).

**Self-host se descarta** aunque sea gratis (Open Edition): añadiría un **cuarto
sistema con logs y fallos propios** a una operación de **una sola persona**. El
coste que importa aquí no es el de la factura, es el operativo.

⚠️ **Ambos free tiers se auto-pausan tras ~1 semana de inactividad** → el ping
nocturno desde el Pi es un requisito, no un detalle.

## Alternativas consideradas

- **LWW con reloj de cliente** — el default de muchas bases de datos, y una fábrica
  de pérdida de datos silenciosa. Descartado.
- **server-receive-time como árbitro** (no solo como orden) — simple, pero hace que
  el que vuelve de estar 5 días sin red pise el trabajo reciente de todos.
- **Vector clocks** — crecen con los dispositivos y no resuelven quién gana.
- **CRDTs ya** — aplazados: no hay señal que los pida, y en gastos el conflicto
  explícito es una *feature*, no un fallo.
- **PowerSync self-host** — gratis en euros, caro en atención humana.

## Consecuencias

- El contrato ya tenía `ETag`/`If-Match` (R1): aquí queda **elevado a árbitro
  oficial** de conflictos. Todo recurso editable debe emitir ETag.
- **La guía de contrato (`docs/backend/guia-contrato-openapi.md` §5–§6) debe
  actualizarse**: `If-Match` pasa a ser obligatorio también en `DELETE` de recursos
  editables (manteniendo el `204` en el reintento de algo ya borrado).
- El esquema del itinerario nace con **fractional indexing**, no con enteros.
- El test de paridad RLS↔sync-rules es un **gate de CI**, no una buena intención.
- Los docs dejan de decir "local-first" y dicen *offline-first*.
- El ping nocturno del Pi pasa a ser infraestructura crítica (sin él, el backend
  se pausa solo).

## Fuentes

- Ink & Switch, *Local-first software* (los 7 ideales): https://www.inkandswitch.com/essay/local-first/
- Kulkarni, Demirbas et al., *Hybrid Logical Clocks*: https://cse.buffalo.edu/tech-reports/2014-04.pdf
- Kleppmann (DDIA), LWW y pérdida de escrituras por clock skew: https://timilearning.com/posts/ddia/part-two/chapter-5/
- Shapiro et al., *CRDTs*: https://crdt.tech/
- PowerSync, *Sync rules*: https://docs.powersync.com/usage/sync-rules · *RLS and sync rules*: https://docs.powersync.com/usage/sync-rules/rls-and-sync-rules · *Client parameters (no confiables)*: https://docs.powersync.com/sync/rules/client-parameters
- PowerSync, *Local-first software* (se describe como sync engine): https://docs.powersync.com/resources/local-first-software
- EDPB, Guidelines 5/2019 (derecho al olvido; crypto-shredding): https://www.edpb.europa.eu/
