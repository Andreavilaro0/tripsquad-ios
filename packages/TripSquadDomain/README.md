# TripSquadDomain

El motor de saldos de TripSquad, como **servicio de dominio puro en Swift** — sin
base de datos, sin red, sin framework. Es la base **compartida** entre el servicio
backend (Hummingbird, Linux) y la app iOS (saldo optimista offline), de modo que
ambos calculan el dinero con el mismo código y no pueden divergir (ADR-0015 §3).

## Qué hace

- **`balances(_:)`** — saldos netos de cada miembro a partir de los gastos. Suma
  cero por construcción.
- **`liquidar(_:)`** — sugiere las transferencias que dejan todo a cero, en dos
  pasadas (subgrupos de suma cero + greedy), con cota dura `|T| ≤ N−1`.
- **`cuotas(de:)`** — reparte un gasto (igual / por peso / exacto) con *largest
  remainder*: la suma de cuotas es siempre exactamente el importe.
- **`Dinero`** — frontera decimal ↔ `Int64` de céntimos. `Double` está prohibido en
  todo el camino del dinero (ADR-0011 §2).

## Reglas inmutables

- **Todo el dinero es `Int64` de unidades menores** (céntimos). Nunca `Double`.
- **Determinismo total:** la misma entrada da la misma salida, byte a byte. Los
  desempates son estables por `miembroId`.
- **El dominio es puro:** solo depende de `Foundation`. No conoce Hummingbird,
  Postgres ni SwiftUI. Un gate de CI lo verifica (bead 9dn).

## Desarrollo

```bash
cd packages/TripSquadDomain
swift test                        # 33 pruebas (16 invariantes property-based + oro + errores)
swift run generate-golden-vectors # regenera golden-vectors.json (506 casos)
```

Los **golden vectors** (`golden-vectors.json`) son el contrato del motor: el port de
Kotlin (Android, futuro) deberá reproducirlos byte a byte como gate de CI (bead 0i9).

Fuentes: `docs/decisions/0011-motor-de-saldos.md` y
`docs/decisions/0015-correcciones-fase-r-y-framework-http.md`.
