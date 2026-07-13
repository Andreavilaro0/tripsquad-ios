# ADR-0011 — Motor de saldos: algoritmo, dinero, FX e invariantes

- **Fecha:** 2026-07-14
- **Estado:** proposed
- **Dueña:** Andrea
- **Origen:** bead R3 (`TripSquad-iOS-2bq`), design doc Backend F3
- **Depende de:** ADR-0009 (estructura), ADR-0010 (Gasto/Liquidación, `Dinero`)

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
PARTITION) — no se intenta calcular exacto. El greedy no siempre es óptimo (hay
contraejemplos donde da 4 transferencias en vez de 3), pero para un squad
(N ≤ 12) la diferencia es de 0–1 transferencias. **Se asume conscientemente.**

**Determinismo obligatorio:** el desempate en el heap es **estable por
`miembroId`** — dos deudores con la misma deuda se ordenan siempre igual. Sin
esto, la misma entrada podría producir liquidaciones distintas.

**Restricciones de producto (reglas de Splitwise, protegen la confianza):**
todos acaban con el mismo neto que antes · nadie acaba debiendo a alguien a
quien no debía · nadie paga más en total del que debía. La regla 2 impide
algunas simplificaciones óptimas: **se prioriza la trazabilidad social sobre el
mínimo absoluto** ("¿por qué le pago a Marta si comí con Iván?"). La
simplificación se ofrece con el detalle "de dónde sale esto" siempre visible.

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

**Orden determinista (decisión de producto):** por defecto, **orden estable por
`miembroId`** — reproducible y testeable. Alternativa documentada: que el céntimo
extra lo asuma el pagador (percepción de justicia). **Queda prohibido** que el
orden dependa de la BD o de un `Set` sin ordenar.

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

**Sobre `settle`:** (9) corrección — aplicar las transferencias deja todos los
saldos a 0; (10) suma cero de transferencias por persona; (11) `|T| ≤ N−1`;
(12) positividad (importe > 0; nunca `p → p`); (13) **nadie paga de más** — un
acreedor jamás aparece como pagador; (14) **idempotencia** — simplificar lo ya
simplificado no hace nada; (15) determinismo byte a byte; (16) estabilidad ante
permutación.

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

- **Buscar el mínimo exacto de transferencias** — NP-completo; para N ≤ 12 el
  greedy queda a 0–1 transferencias del óptimo. Descartado por complejidad sin
  beneficio percibible. (Mejora barata futura: detectar subgrupos de suma cero de
  tamaño 2 y 3 antes del greedy.)
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

## Pendiente de firma de Andrea (producto)

1. **¿Quién asume el céntimo sobrante?** Por defecto, orden estable por
   `miembroId` (determinista, arbitrario). Alternativa: lo asume el pagador
   (más "justo" a la vista del usuario).
2. **¿La simplificación de deudas es opt-in por viaje?** Recomendado: sí, y con el
   desglose siempre accesible — simplificar agresivamente rompe la trazabilidad
   social del gasto.

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
