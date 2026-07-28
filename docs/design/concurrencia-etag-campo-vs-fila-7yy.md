# Investigación: control de concurrencia — `If-Match` a la fila entera vs. versionado por CAMPO (bead 7yy)

> **Estado: BORRADOR DE INVESTIGACIÓN — decisión pendiente de Andrea.**
> Esto NO es un ADR. Es material de soporte para que Andrea dirija la decisión y
> firme el ADR que fije (o confirme) el mecanismo de concurrencia. La constitution
> reserva las decisiones de arquitectura a Andrea; aquí solo se exponen las opciones
> reales, sus trade-offs y una recomendación **tentativa**, para que la valore. No se
> implementa código. Referencias: ADR-0013 §2/§3, ADR-0015 §2/§12, ADR-0027,
> `docs/backend/contrato-sync-upload.md` §1.

## El problema (el conflicto falso que nadie quiere)

Hay una **tensión latente** entre dos decisiones ya firmadas:

- **ADR-0013 §3** paga desde hoy el **versionado por CAMPO** ("Versionado por CAMPO,
  no por fila entera"), como preparación de CRDTs.
- Pero el **control de concurrencia** —el árbitro del conflicto— sigue siendo
  **`ETag`/`If-Match` a la FILA entera** (ADR-0013 §2, ADR-0015 §2/§12): el cliente
  manda el ETag que conocía de **toda la fila** y, si no coincide, hay conflicto.

El choque es concreto. Un gasto tiene, entre otros, los campos `categoría` e
`importe`. Sin cobertura:

```
  ETag de partida de la fila del gasto: v7

  Iván  edita  categoría: "Comida" → "Transporte"     (envía If-Match: v7)
  Marta edita  importe:   40,00 €   → 45,00 €          (envía If-Match: v7)

  El primero en sincronizar (Iván) aplica  → la fila pasa a v8.
  El segundo (Marta) manda If-Match: v7 ≠ v8  → CONFLICTO.
```

Pero Iván y Marta **editaron campos distintos**. No hay ninguna razón real para que
Marta reciba un conflicto: su cambio de `importe` es perfectamente compatible con el
cambio de `categoría` de Iván. Es un **conflicto falso**, producto de que el árbitro
mira la fila entera mientras el dato ya se versiona por campo.

Con dinero, además, esto tiene un coste doble: los conflictos de gasto **se muestran a
la usuaria** (ADR-0015 §12, estado `conflicted` con su pantalla propia). Un conflicto
falso es una interrupción injustificada — "Iván cambió esto mientras no tenías
cobertura" cuando en realidad **no** tocó lo que Marta tocó.

**Por qué importa más allá de la UX:** el ratio de 412/conflictos es, literalmente, la
**señal de activación de CRDTs** (ADR-0013 §3: "cuando más del 2 % de las escrituras
devuelvan 412"). Los conflictos falsos **inflan esa señal** y podrían disparar la
adopción de CRDTs —cara— por un problema que no es de merge, sino de granularidad del
árbitro. Ver §"Relación con el criterio de CRDTs".

## Contexto: lo que ya está decidido y no se re-litiga

- El **árbitro NO es un reloj** (ADR-0013 §2). Es `ETag`/`If-Match`. Eso no se toca:
  cualquier opción de abajo sigue usando precondiciones, no timestamps.
- En el **camino de la cola**, un conflicto **no devuelve 412** sino **200 + fila en
  `write_conflicts`** (ADR-0015 §2), para no congelar la cola. La granularidad del
  conflicto (fila vs. campo) es ortogonal a ese código HTTP: se decide *qué* cuenta
  como conflicto, no *cómo* se responde.
- **Los gastos NO quieren CRDT** (ADR-0013 §3): con dinero, un conflicto explícito es
  **deseable** — que dos ediciones se fundan solas en silencio es peor que preguntar.
  Esto acota el problema: no buscamos "merge mágico", buscamos **no molestar cuando no
  hay nada que resolver**.
- El dato por campo **ya existe**: `expense_revisions` (ADR-0015 §15, ADR-0027) guarda
  `field · old_value · new_value`. El versionado por campo no es teórico; está escrito.
- `If-Match` es obligatorio en update/delete de fila sincronizada; los *creates* se
  protegen con la PK de cliente (ADR-0015 §12). Nada de esto cambia.

## Opciones reales

### Opción A — `ETag` por CAMPO (`If-Match` de campo)

Cada campo (o grupo de campos) lleva su **propia versión**; el `If-Match` viaja por
campo y el servidor solo compara la precondición de los campos que la operación toca.
Dos ediciones a campos disjuntos **nunca colisionan**; solo choca quien edita el
**mismo** campo con una versión rancia.

- **A favor:** elimina el conflicto falso de raíz; es el modelo más fino y el más
  alineado con "versionado por campo" de ADR-0013 §3; el conflicto que queda es
  **siempre real** (mismo campo, dos manos).
- **En contra:** el ETag deja de ser un escalar opaco por fila y pasa a ser un **mapa
  de versiones por campo** — más peso en el contrato, en el `Schema` del cliente y en
  la máquina de estados de escritura (ADR-0015 §12). Hay que definir la **granularidad
  del "campo"** (¿`importe` y `divisa` son un campo o dos? el reparto, ¿un campo o N?).
  Toca el shape de `/sync/upload` §1 (hoy `ifMatch` es un solo `"v7"`).

### Opción B — Merge sin conflicto cuando los campos NO solapan (ETag de fila + detección por campo)

El ETag sigue siendo **uno por fila** en el contrato (mínimo cambio de superficie),
pero el **servidor** resuelve el conflicto con grano fino: cuando llega un `If-Match`
rancio, en vez de declarar conflicto a ciegas compara **qué campos** cambió esta
operación contra **qué campos** cambiaron entre el ETag del cliente y el actual
(el dato de `expense_revisions` da exactamente eso). Si los conjuntos de campos son
**disjuntos**, aplica el cambio y **avanza el ETag** (no hay conflicto); si **solapan**,
es conflicto real → 200 + `write_conflicts` (ADR-0015 §2).

- **A favor:** el contrato de cara al cliente casi no cambia (sigue un `ifMatch` por
  fila); reutiliza `expense_revisions`, que ya se escribe; el conflicto falso
  desaparece **sin** exponer un mapa de versiones. Mantiene la promesa de "conflicto
  explícito para dinero" **solo cuando de verdad hay colisión de campo**.
- **En contra:** la lógica de merge por campo vive en el **servidor** y hay que
  probarla con cuidado (¿qué pasa con dos ediciones al mismo campo con el mismo valor?
  ¿con el reparto, que es semi-estructurado?); "avanzar el ETag" tras un merge implica
  que el cliente perdedor debe **refrescar** su copia (el resultado no es el que envió,
  sino el fusionado) — necesita un `outcome` nuevo tipo `merged` en el contrato §3, no
  solo `accepted`/`conflict`.

### Opción C — Statu quo: `If-Match` a la fila entera

Se deja como está: cualquier edición concurrente a la misma fila —toque los campos que
toque— produce conflicto. La usuaria resuelve (quedarme con la mía / con la suya / ver
diferencias, ADR-0015 §12).

- **A favor:** cero trabajo nuevo; el modelo más simple y ya especificado; para dinero,
  "ante la duda, pregunta" es defendible. Con squads pequeños y edición
  **poco** concurrente sobre la **misma** fila, los conflictos falsos pueden ser raros.
- **En contra:** genera conflictos falsos molestos en cuanto dos personas tocan el
  mismo gasto a la vez (caso real en un viaje: alguien ajusta la categoría mientras
  otro corrige el importe); **infla artificialmente** la señal del 2 % de 412 que
  dispara los CRDTs (ADR-0013 §3), pudiendo provocar una decisión cara por un motivo
  equivocado.

## Recomendación TENTATIVA (para que Andrea decida, no decidida)

**Opción B como primer paso; Opción A solo si B se queda corta.**

Razonamiento:

1. **B resuelve el problema real** (el conflicto falso) con la **mínima** ampliación de
   contrato: un `outcome: "merged"` en la respuesta §3 y la lógica de solape en el
   servidor. El cliente sigue mandando un `ifMatch` por fila.
2. **Reutiliza lo que ya existe:** `expense_revisions` (ADR-0027) ya registra el cambio
   **campo a campo**; el motor de solape se alimenta de ese mismo dato, no de una
   estructura nueva.
3. **Preserva la decisión firmada de "conflicto explícito para dinero"** (ADR-0013 §3):
   B **no** funde valores del mismo campo — dos ediciones al `importe` siguen dando
   conflicto visible. Solo elimina el ruido de campos disjuntos.
4. **A es más pura** (versión por campo de punta a punta) y es el destino natural si el
   itinerario —que sí quiere co-edición— empuja hacia versiones por campo; pero hoy su
   coste (mapa de ETags en contrato + cliente + máquina de estados) **no está
   justificado** para el slice de gastos, que es donde muerde el problema.

En una frase: **empezar moviendo la inteligencia del conflicto al servidor (B), sin
tocar la forma del ETag del cliente, y reservar el ETag-por-campo (A) para cuando el
itinerario o un ratio de conflicto real lo pidan.**

## Relación con el criterio de activación de CRDTs (ADR-0013 §3)

Esto es lo más importante de decidir **bien**, porque contamina una decisión mayor:

- ADR-0013 §3 activa CRDTs cuando **> 2 % de las escrituras devuelven 412** (o cuando
  aparece texto libre coeditado). Ese umbral **asume que los 412 son conflictos
  reales**.
- Con la Opción C, **cada conflicto falso cuenta como un 412**. Dos personas tocando
  campos distintos del mismo gasto inflan el ratio sin que exista ninguna colisión de
  merge. Se podría **cruzar el 2 % por ruido** y disparar la adopción de CRDTs —cara, y
  que ADR-0013 §3 dice explícitamente que **los gastos no quieren**.
- La Opción B (y la A) hacen que el ratio de conflicto mida **conflictos reales de
  campo**. Así el 2 % vuelve a significar lo que ADR-0013 quería: "hay verdadera
  co-edición del mismo dato, quizá toca CRDT". Es decir: **arreglar la granularidad del
  árbitro sanea la propia señal que gobierna los CRDTs.**

Implicación para Andrea: elegir B/A no es solo pulir UX; es **evitar que una decisión
de producto (adoptar CRDTs) se dispare por un artefacto de medición**. Si se queda en
C, conviene al menos **instrumentar por separado** "conflictos de fila" vs. "conflictos
con solape real de campo", para que el umbral del 2 % no se lea sobre el número inflado.

## Preguntas abiertas para Andrea

- ¿**B** (merge servidor por campos disjuntos, ETag de fila) o **A** (ETag por campo de
  punta a punta) para el slice de gastos? ¿O **C** (statu quo) aceptando el ruido y
  midiendo el 412 con cuidado?
- Si **B**: ¿qué es un "campo" a efectos de solape — `importe`+`divisa` juntos?, ¿el
  reparto es un campo o N (uno por miembro)? La respuesta define cuándo dos ediciones
  "solapan".
- ¿Se introduce el `outcome: "merged"` en el contrato de `/sync/upload` §3 ahora, o se
  difiere hasta conectar el primer endpoint de edición de gasto a Postgres?
- ¿El umbral del 2 % de ADR-0013 §3 se mide sobre conflictos **reales de campo** (lo que
  B/A permiten) o se re-expresa explícitamente para no contar los falsos?
- ¿Alcance? Esto muerde en **gastos** hoy; el **itinerario** (que sí quiere co-edición,
  ADR-0013 §3) podría empujar antes hacia A. ¿Se decide solo para gastos o se fija el
  rumbo para ambos?
