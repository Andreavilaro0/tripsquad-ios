# Diseño — Confirmaciones (PDF/email) → auto-marca el wedge (bead dy5)

> **Estado:** DISEÑO (pendiente de revisión de Andrea). Decisiones tomadas en brainstorming 2026-07-25.
> **Origen:** idea de Andrea + `docs/research/hallazgos.md` (parseo de confirmaciones = table-stakes, TripIt). Complementa el wedge (ADR-0024, ya en develop).
> **Alcance:** SOLO back (Swift). La UI de subir/compartir y elegir el reservable vive en la app iOS.

## Goal

"Reenvía tu billete y el tablero se marca solo": el usuario sube una confirmación (PDF/texto) de vuelo/hotel; el back extrae los datos y **marca su reserva como `reservado` en el wedge**, guardando el nº/fecha como evidencia. Convierte "¿habéis reservado todos?" en algo que se rellena solo al subir el billete.

## Decisiones (brainstorming 2026-07-25)

1. **La IA corre en una API china en la nube** (DeepSeek/GLM/Qwen — coste). ⚠️ **Andrea ACEPTÓ explícitamente la transferencia RGPD** (datos de usuarios UE → China, sin decisión de adecuación) tras advertírselo. Salvaguardas obligatorias en el diseño (ver §RGPD).
2. **Auto-marca el wedge directamente** — no hay bandeja de "confirmaciones" aparte; reusa el wedge existente.
3. **Entrada: subir/compartir desde la app** (PDF o texto) — sin infra de correo entrante (el "reenviar email estilo TripIt" queda para una iteración posterior).
4. **Matching en la app, marca en el back** — la app (que ya tiene los reservables cargados) deja al usuario elegir/confirmar el reservable destino y manda `activityId`. El back NO hace matching difuso.
5. **Quién = el actor** (quien sube la confirmación es la persona cuya reserva se marca).

## Flujo

1. La app extrae el texto del PDF (o el usuario pega texto) y deja elegir el reservable destino.
2. `POST /trips/:tripId/itinerary/:itemId/reservation/confirmation` con `{ confirmationText }` (+ `Idempotency-Key`). El actor sale del JWT.
3. El back **minimiza + envía el texto** al LLM chino (detrás de un puerto), con **salida estructurada** → `{ tipo, fechaISO?, numeroConfirmacion?, proveedor? }`.
4. El back **guarda esos campos** como confirmación de la reserva del actor en ese reservable, y **marca el estado del actor = `reservado`** (reusa `CasosDeUsoReserva`).
5. La app refleja "✅ reservado · nº ABC123".

## Componentes de back

### 1. Puerto `EstructuradorConfirmacion` (frontera con el LLM)
```swift
public struct DatosConfirmacion: Equatable, Sendable {
    public let tipo: KindReserva          // reusa el enum del wedge (vuelo/hotel/...)
    public let fechaISO: String?          // 'YYYY-MM-DD'
    public let numeroConfirmacion: String?
    public let proveedor: String?
}
public protocol EstructuradorConfirmacion: Sendable {
    func extraer(textoConfirmacion: String) async throws -> DatosConfirmacion
}
```
- Impl real = API china (DeepSeek/GLM/Qwen) con **salida estructurada** (JSON schema/function-calling) → el modelo SOLO puede devolver la forma de `DatosConfirmacion`, no seguir instrucciones (defensa anti-prompt-injection: el texto de la confirmación es DATO hostil).
- Impl de test = fake determinista.
- Proveedor concreto + **doc real vía Context7 (regla 6)** se fijan en el PLAN, no aquí. Detrás del puerto → intercambiable.

### 2. Modelo — confirmación adjunta a la reserva
La reserva por-persona del wedge gana un campo opcional de confirmación:
```swift
public struct Confirmacion: Equatable, Sendable {
    public let tipo: KindReserva
    public let fechaISO: String?
    public let numeroConfirmacion: String?
    public let proveedor: String?
}
```
Se guarda por `(activityId, memberId)` en el modo `cadaUnoElSuyo`, o por `(activityId)` en `unoParaTodos`. Nueva columna/tabla `itinerary_reservation_confirmations` (o campos en las tablas del wedge). Migración `0009`.

### 3. Caso de uso `CasosDeUsoReserva.registrarConfirmacion`
- Auth: reusa el gate del wedge — actor miembro; en `cadaUnoElSuyo` el actor debe estar incluido; viaje cerrado = solo lectura; sin fuga de existencia.
- Llama al `EstructuradorConfirmacion`, guarda la `Confirmacion`, y marca `reservado` (reusa la lógica de `marcar`). Si el LLM falla → `reglaViolada("confirmacion_ilegible")` (fallback: el usuario marca a mano, que el wedge ya permite).
- Idempotente por `Idempotency-Key`.

### 4. Endpoint
`POST /trips/:tripId/itinerary/:itemId/reservation/confirmation`, body `{ confirmationText }`. Auth miembro; mapeo de error como el wedge (`noAutorizado`→403, `viajeCerrado`→409, `reglaViolada`→422).

## RGPD (transferencia aceptada por Andrea — salvaguardas obligatorias)

- **Consentimiento:** la app debe pedir consentimiento explícito antes de enviar una confirmación a la IA (transferencia a China). Registrado.
- **Minimización:** enviar SOLO el texto de la confirmación, y **redactar** lo que no haga falta (nº de tarjeta, datos de pago, direcciones personales) antes de mandarlo. El back redacta patrones sensibles.
- **Base de transferencia:** documentar SCCs / base legal en el ADR; sin PII innecesaria.
- **ADR nuevo** registra la decisión, el proveedor, y estas salvaguardas.
- Alternativas más limpias que Andrea descartó por ahora (dejar anotadas): on-device, o modelo chino abierto auto-alojado en la UE (RGPD limpio). Si el volumen/riesgo crece, reconsiderar.

## Fuera de alcance v1
- **Reenviar email** (dirección por viaje) — infra de correo entrante, iteración posterior.
- **Guardar el PDF binario** — necesita FotoStorage real (bead 7n3, stub). v1 guarda solo los campos extraídos + (opcional) el texto, no el binario.
- **Matching difuso** en el back — lo hace la app.
- **Auto-detección de la persona** por el nombre del pasajero — v1 = el actor que sube.

## Tests
- Caso de uso con `EstructuradorConfirmacion` **fake**: registra confirmación → guarda campos + marca `reservado`; **test de prompt-injection** (texto malicioso → la salida sigue siendo `DatosConfirmacion`, no ejecuta instrucciones); **test de redacción** (nº de tarjeta se redacta antes de enviar); LLM falla → `reglaViolada("confirmacion_ilegible")`.
- Auth (reusa la matriz del wedge): no-miembro → noAutorizado; no-incluido → reglaViolada; viaje cerrado → viajeCerrado.
- Ruta: 403/409/422, idempotencia, `missing_idempotency_key`→400.
- Repo Postgres: round-trip de la confirmación, cascada con la actividad.

## Dependencias
- Reusa: el wedge (`Reserva`/`CasosDeUsoReserva`/rutas, ADR-0024), `KindReserva`, la infra de auth.
- Nuevo: puerto `EstructuradorConfirmacion` + adaptador LLM chino (API de pago china; su doc por Context7 en el plan), migración `0009`.
- NO depende de FotoStorage (7n3) ni del recibo→split.

## Beads
- Cerrar/reencuadrar `dy5` apuntando a este spec. La parte de "reenviar email" y "guardar PDF" se separan a beads propios.
