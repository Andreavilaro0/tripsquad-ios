# ADR-0011 — Motor de saldos: algoritmo, dinero, FX e invariantes

- **Fecha:** 2026-07-14
- **Estado:** accepted
- **Firmado:** 2026-07-14 por Andrea ("firma los ADRs y mergea todo" — firma por
  delegación. Las decisiones de producto se resolvieron con los defaults
  recomendados; **Andrea conserva el derecho de veto** vía ADR nuevo).
- **Dueña:** Andrea
- **Origen:** bead R3 (`TripSquad-iOS-2bq`), design doc Backend F3
- **Depende de:** ADR-0009 (estructura) · ADR-0010 (Gasto/Liquidación, `Dinero`,
  `MiembroId`) — **en revisión en el PR #10; este ADR debe fusionarse después.**
  Mientras tanto, el contrato de dinero vigente está en
  `docs/backend/guia-contrato-openapi.md` §9 (string decimal + `currencyCode`).

## Contexto

El motor de saldos es el corazón del valor de TripSquad y el sitio donde un
error destruye la confianza ("un error de duplicidad en saldos invalida el
viaje"). Vive como **servicio de dominio puro en Swift**, sin base de datos, y
se demuestra correcto con property-based tests. Este ADR fija el algoritmo, la
representación del dinero, la política de FX, las invariantes verificables y el
harness de tests.

## Decisión

### 1. Algoritmo: netos + greedy, con la verdad sobre el óptimo

1. **Saldos netos primero.** `neto(p) = Σ(pagado por p) − Σ(asignado a p)`. Por
   construcción `Σ neto = 0`. Colapsa el grafo denso de deudas bilaterales en un
   vector de N números. Coste O(E).
2. **Liquidación por greedy max-deudor / max-acreedor:** empareja al que más debe
   con al que más se le debe, transfiere `min(|deuda|, crédito)`, repite. Cada
   iteración deja al menos a uno a cero → **cota dura de N−1 transferencias**.
   Coste O(N log N).

**El mínimo absoluto de transferencias es NP-completo** (reducción desde
PARTITION) — no se busca el óptimo exacto.

**El greedy puede quedarse bastante lejos del óptimo, también con squads
pequeños.** Contraejemplo verificado (7 saldos, dentro de nuestro rango):
`[−14, −13, +14, +13, +7, +11, −18]` → el greedy emite **6 transferencias**,
mientras que partir en subgrupos de suma cero (`[−14,+14]`, `[−13,+13]`,
`[−18,+7,+11]`) las salda en **4**. La cota real es la dura: `|T| ≤ N−1`.

Por eso el motor hace **dos pasadas**, no una:

1. **Descomposición en subgrupos de suma cero pequeños** (pares y tríos). Cada
   subgrupo de tamaño *m* se salda con *m−1* transferencias. Es barato
   (O(N²)/O(N³) sobre N ≤ 12 miembros: nada) y captura la mayor parte de la
   mejora — en el contraejemplo, toda.
2. **Greedy sobre el resto**, con la cota `N−1` como garantía.

Sigue sin ser el óptimo exacto (eso es NP-completo y no se persigue), pero ya no
se afirma una cercanía al óptimo que es falsa. La **invariante de tamaño** que se
testea es `|T| ≤ N−1`; adicionalmente, se comprueba que la salida de dos pasadas
**nunca es peor** que la del greedy solo.

**Determinismo obligatorio:** el desempate en el heap es **estable por
`miembroId`** — dos deudores con la misma deuda se ordenan siempre igual. Sin
esto, la misma entrada podría producir liquidaciones distintas.

**Restricciones de producto — hay que elegir, no se pueden tener las tres.**
Las reglas de Splitwise son: (1) todos acaban con el mismo neto que antes;
(2) nadie acaba debiendo a alguien a quien no debía; (3) nadie paga más en total
del que debía.

**Liquidar a partir de netos cumple (1) y (3), pero NO puede cumplir (2)** — y es
matemáticamente inevitable, porque el vector de netos **descarta el grafo de
deudas original**. Contraejemplo: deudas B→A 5, D→C 10, D→A 5 dan netos
`A +10, C +10, B −5, D −15`, y el greedy puede emitir **B→C 5** aunque B nunca le
debió nada a C.

**Decisión (dos modos explícitos, el usuario elige):**

- **Modo detallado (por defecto):** no se simplifica. Se muestran las deudas tal
  como nacieron, respetando el grafo original. Cumple las tres reglas
  trivialmente. Es el modo honesto para un squad de amigos, donde la trazabilidad
  social importa más que el número de Bizums ("¿por qué le pago a Marta si comí
  con Iván?").
- **Modo simplificado (opt-in por viaje):** liquidación por netos con las dos
  pasadas de arriba. Minimiza transferencias, y **se admite explícitamente que
  puede crear deudas entre personas que no se debían nada** — la regla (2) se
  suelta de forma consciente, no por descuido. La UI **debe** avisarlo y mantener
  el desglose "de dónde sale esto" siempre accesible.

Se descarta implementar un `settle` restringido al conjunto de aristas originales
(que cumpliría las tres): añade complejidad al núcleo y, en la práctica, produce
resultados poco mejores que el modo detallado. Si algún día se pide, es un ADR
nuevo.

### 2. Dinero: `Int64` en unidades menores, nunca `Double`

- **Núcleo del dominio: `Int64` de unidades menores** (céntimos). Es el *Money
  pattern* de Fowler y lo que hace Stripe (`1099` = 10,99 €). Elimina el error de
  redondeo **por diseño**.
- **`Decimal` solo en la frontera**, para parsear/formatear el string decimal del
  contrato. Trampa documentada: `Decimal(0.1)` desde literal `Double`
  **reintroduce el error binario** — se usa siempre `Decimal(string:)`.
- Flujo: `String → Decimal(string:) → Int64 minorUnits` a la entrada; el motor
  opera **solo con Int64**; `Int64 → String` a la salida con el exponente ISO 4217
  de la divisa (2 para EUR, **0 para JPY** — divisas zero-decimal).
- **`Double` queda prohibido en todo el camino del dinero.** `0.1 + 0.2 ≠ 0.3` en
  binario: acumular saldos con `Double` rompe la invariante de suma cero.

### 3. El reparto que no cuadra: largest remainder

10 € entre 3 personas = 333 + 333 + 333 = 999 céntimos. **Se pierde 1 céntimo, y
ningún modo de redondeo lo arregla** — no es un problema de rounding, es un
problema de reparto.

```
base = total / n           (división entera)
rem  = total % n
a los primeros `rem` participantes, en orden determinista, se les suma 1 céntimo
```
→ `334 + 333 + 333 = 1000`. **Conservación exacta por construcción.** Para
repartos por peso: `floor(total * wᵢ / Σw)`, ordenar por parte fraccionaria
descendente y repartir los restos uno a uno.

**Orden determinista (decisión de producto, firmada en §8):** los céntimos
sobrantes los asume **el pagador del gasto**; si sobran más céntimos que la cuota
del pagador (caso degenerado), el resto se reparte en **orden estable por
`miembroId`**. Es determinista (el pagador es un dato del gasto) y se percibe como
justo: quien adelantó el dinero absorbe el resto, nunca un participante al azar.
**Queda prohibido** que el orden dependa de la BD o de un `Set` sin ordenar.

### 4. Redondeo: half-even solo en FX

- En el reparto de un total fijo, el modo de redondeo es **irrelevante** (división
  entera + largest remainder; no hay empates que resolver).
- **El motor de saldos no redondea nunca**: opera en enteros y solo reparte restos.
- Half-even (bancario) se usa **únicamente en la conversión FX**, donde sí hay
  pérdida y muchas operaciones: evita el sesgo sistemático al alza de half-up.

### 5. FX: la tasa se congela en el gasto

**La tasa se aplica al registrar el gasto y jamás se recalcula al liquidar.** Es
el principio de IAS 21 (tipo spot de la fecha de la transacción).

Columnas a crear **ya**, aunque el MVP sea mono-divisa: `amount_original`,
`currency_original`, `fx_rate`, `fx_rate_source`, `fx_rate_at`,
`currency_reference` (divisa del viaje, fijada al crearlo), `amount_reference`
(derivado y **congelado**).

**El motor solo ve `amount_reference` en céntimos** → el core se mantiene
mono-divisa y puro; FX es un adaptador en la frontera (2º incremento).

Si no se congela: los saldos de un viaje pasado **cambiarían solos** al moverse el
mercado (deudas que mutan sin que nadie toque nada), la suma-cero se rompe por
redondeo, y la liquidación deja de ser auditable ("¿por qué debía 12,40 €?").

### 6. Invariantes property-testeables

**Sobre `balances`:** (1) **suma cero** — la invariante maestra; (2) conservación
del total (ningún céntimo se crea ni se destruye); (3) `Σ cuotas(gasto) ==
importe(gasto)` exacto; (4) en reparto equitativo, `max(cuota) − min(cuota) ≤ 1`
céntimo; (5) **determinismo y permutación** — `balances(shuffle(E)) ==
balances(E)`: el orden de los gastos no afecta a los saldos (mata bugs de
acumulación e iteración sobre `Set`); (6) elemento neutro (gasto de importe 0, o
que el pagador se asigna entero a sí mismo, no cambia nada); (7) aditividad;
(8) inverso.

**Sobre `settle` (modo simplificado):** (9) corrección — aplicar las
transferencias deja todos los saldos a 0; (10) suma cero de transferencias por
persona; (11) **`|T| ≤ N−1`** (la cota dura; **no** se testea cercanía al óptimo,
que sería falsa) y la salida de dos pasadas nunca es peor que la del greedy solo;
(12) positividad (importe > 0; nunca `p → p`); (13) **nadie paga de más** — un
acreedor jamás aparece como pagador; (14) **idempotencia** — simplificar lo ya
simplificado no hace nada; (15) determinismo byte a byte; (16) estabilidad ante
permutación.

**Nota:** NO se testea "nadie debe a quien no debía" en modo simplificado —
liquidar por netos no puede garantizarlo (§1), y el modo detallado lo cumple por
construcción al no simplificar.

**Sobre FX (2º incremento):** (17) **congelación** — recalcular con una tabla de
tasas distinta, pero los mismos gastos con su `fx_rate` guardada, da **los mismos
saldos**; (18) convertir un importe ya en divisa de referencia (tasa 1) es la
identidad exacta.

Generadores: grupos de 2–12 miembros, 0–200 gastos, importes 1…10⁷ céntimos,
repartos equitativos / por partes / por porcentajes, pagadores repetidos, e
importes que **fuerzan restos** (primos, coprimos con el número de participantes).

### 7. Harness: PropertyBased (`x-sheep/swift-property-based`)

Estado real del ecosistema (datos de la API de GitHub, 2026-07-14):

| Librería | Última release | Estado |
|---|---|---|
| `typelift/SwiftCheck` | 0.12.0 — **mar 2019** | **muerto** (sin Swift 6, sin swift-testing) |
| `x-sheep/swift-property-based` | **1.2.0 — abr 2026** | vivo, 13 releases |
| `Aristide021/SwiftQC` | v1.0.0 — jul 2025 | 1 release, sin actividad desde 2025 |
| `pointfreeco/swift-gen` | 0.5.0 — ago 2025 | vivo, pero **solo generadores** |

- **swift-testing de Apple NO tiene PBT nativo**: sus *parameterized tests* son
  casos enumerados, sin generación aleatoria ni **shrinking**.
- **SwiftCheck queda descartado**: 7 años sin release; adoptarlo es deuda técnica
  el día 1 (el design doc ya lo sospechaba: "SwiftCheck está flojo").
- **swift-gen** aporta generadores componibles pero no hace shrinking ni reporta
  contraejemplos: es una pieza, no la solución.

**Se elige PropertyBased** porque: se integra nativamente en swift-testing
(Swift 6.2 / Xcode 26); hace **shrinking automático** (cuando falle la suma-cero
con 47 gastos, quieres el contraejemplo mínimo de 2 gastos y 3 personas, no un
volcado); reporta la **semilla** del fallo, lo que convierte un fallo de CI en un
test de regresión determinista; y no depende de Foundation, así que el dominio
puro sigue siendo portable a Linux (donde vivirá el backend).

**Mitigación del bus-factor** (18 estrellas, un autor): las invariantes son texto
(§6) y el motor es un servicio de dominio puro. Si PropertyBased desapareciera,
portarlas a generadores propios (RNG semillable + runner de 200 iteraciones) es
un día de trabajo. **El dominio no se acopla al framework de tests.**

Plan: PropertyBased para las 18 invariantes + `@Test(arguments:)` de
swift-testing para los casos de oro (10 €/3, JPY zero-decimal, 1 céntimo entre 5,
grupo de una persona).

## Alternativas consideradas

- **Buscar el mínimo exacto de transferencias** — NP-completo. Descartado: la
  descomposición en subgrupos de suma cero (pasada 1) captura la mayor parte de la
  mejora a coste trivial para N ≤ 12.
- **`settle` restringido al grafo de deudas original** (cumpliría las tres reglas
  de Splitwise a la vez) — descartado: complica el núcleo y da resultados poco
  mejores que simplemente no simplificar (modo detallado). Si se pide, ADR nuevo.
- **`Decimal` en el núcleo del motor** — exacto, pero ~12× más lento que `Double`,
  no conforma `Strideable`, y su inicialización desde literal es una trampa.
  `Int64` en unidades menores es más simple y exacto por diseño.
- **Recalcular FX al liquidar** — daría saldos "actualizados", pero mutarían solos
  y romperían la auditabilidad. Descartado (IAS 21).
- **SwiftCheck** — el harness clásico, pero muerto desde 2019.
- **SwiftQC** — hace lo correcto (shrinking, stateful, swift-testing), pero una
  sola release y sin actividad desde julio 2025: bus-factor peor que PropertyBased.

## Consecuencias

- El motor se implementa **sin DB**, testeable en milisegundos: es la primera pieza
  del slice vertical y su suite de propiedades es un gate de CI.
- El esquema de gastos nace con las columnas de FX aunque el MVP sea mono-divisa:
  añadirlas después obligaría a migrar datos de dinero ya escritos.
- La guía de contrato (R1) queda confirmada: dinero como string decimal +
  `currencyCode`, jamás number.
- Se acepta una dependencia joven (PropertyBased) con plan de salida explícito.
- La simplificación de deudas se presenta **con su detalle**, no como caja negra.

## 8. Decisiones de producto (firmadas por delegación — vetables)

1. **El céntimo sobrante lo asume el pagador del gasto.** Se elige la opción A
   sobre el default técnico: el reparto sigue siendo **determinista** (el pagador
   es un dato del gasto, no depende del orden de la BD ni de un `Set`), y además
   es el que se percibe como justo — quien adelantó el dinero absorbe el céntimo,
   nunca un participante al azar. Cumple la invariante (2) de conservación exacta
   y no introduce ninguna arbitrariedad visible para el usuario.
2. **Modo detallado por defecto; simplificación opt-in por viaje.** La
   simplificación **puede hacer que le pagues a alguien a quien no le debías nada**
   (es matemáticamente inevitable al liquidar por netos, §1). Con el modo detallado
   por defecto, eso solo ocurre si la usuaria lo activa a sabiendas, con el aviso
   y el desglose delante.

**Andrea conserva el derecho de veto** sobre ambas mediante un ADR nuevo.

## Fuentes

- Splitwise, *Debts Made Simple* (reglas de simplificación): https://blog.splitwise.com/2012/09/14/debts-made-simple/
- Alex Irpan, *Splitwise is NP-Complete* (reducción desde PARTITION; contraejemplo del greedy): https://www.alexirpan.com/2016/05/10/may-10.html
- Terbium, *Debt simplification*: https://terbium.io/2020/09/debt-simplification/
- Fowler, *Money pattern* (PoEAA), con `allocate`: https://martinfowler.com/eaaCatalog/money.html
- Stripe, *Currencies* (unidad menor; zero-decimal): https://docs.stripe.com/currencies
- Jesse Squires, *Decimal vs Double* (+ Rob Napier: usa Int en céntimos): https://www.jessesquires.com/blog/2022/02/01/decimal-vs-double/
- IFRS, **IAS 21** (tipo spot en la fecha de la transacción): https://www.ifrs.org/issued-standards/list-of-standards/ias-21-the-effects-of-changes-in-foreign-exchange-rates/
- Swift Testing, *Parameterized Testing* (no hay PBT nativo): https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Testing.docc/ParameterizedTesting.md
- **PropertyBased**: https://github.com/x-sheep/swift-property-based · anuncio: https://forums.swift.org/t/propertybased-easy-quickcheck-for-swift-testing-on-all-platforms/82222
- SwiftCheck (última release 2019): https://github.com/typelift/SwiftCheck · SwiftQC: https://github.com/Aristide021/SwiftQC · swift-gen: https://github.com/pointfreeco/swift-gen

*Datos de mantenimiento (releases, pushes, estrellas) obtenidos vía API de GitHub el 2026-07-14.*
