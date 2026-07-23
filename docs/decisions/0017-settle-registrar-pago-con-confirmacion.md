# ADR-0017 — Registrar pago de `:settle` = pendiente + confirmación de la contraparte

- **Fecha:** 2026-07-23
- **Estado:** accepted
- **Dueña:** Andrea
- **Decide:** Andrea (sesión cockpit multi-IA, 2026-07-23)
- **Supersede:** **ADR-0016 §c** (la parte "registrar pago = POST idempotente que
  responde `registered` de inmediato"). ADR-0016 §a (sugerir, GET puro) y su modelo
  `Settlement`/clave determinista **siguen vigentes**.
- **Depende de:** ADR-0016 (recursos de `:settle`), ADR-0012 (idempotencia por
  `(actor, key)`), ADR-0015 §5 (dedupe estructural con `settlementId` + `transfer_index`),
  ADR-0014 (threat model — actor sale del JWT).

## Contexto

Al implementar ADR-0016 §c (PR #31), el revisor de otro modelo (**Codex**, hallazgo P1
de no-repudio) señaló un agujero real: el POST tomaba el **pagador `from` del body**, y
el caso de uso solo comprobaba que el *actor* fuese miembro. Es decir, un miembro
autenticado podía registrar un pago afirmando que **otro** había pagado (`from: iván,
to: ana` firmado por Ana), sin que Iván interviniese. En cuanto los saldos incorporen
los settlements (bead `xsx`), eso permitiría **saldar deudas ajenas por decreto
unilateral** — la acción más peligrosa del contrato (ADR-0015 §5).

ADR-0016 §c asumía "registrado directo" (idempotente). Eso es correcto para un ledger
de una sola parte, pero **un pago entre dos personas tiene dos versiones de la verdad**
y necesita acuerdo, no imposición.

## Decisión

Un pago (`Settlement`) es una **afirmación entre dos miembros que requiere acuerdo de
ambos**. El registro deja de ser un hecho inmediato y pasa a una máquina de estados:

1. **Cualquiera de las dos partes** miembro del viaje (el que paga `from` **o** el que
   cobra `to`) puede **crear** una afirmación de pago. El `actor` (del JWT) debe ser una
   de las dos partes; no puede registrar pagos entre terceros.
2. La afirmación nace en estado **`pending`**.
3. La **contraparte** (la parte que NO es el `actor` creador) puede **`confirm`** o
   **`reject`**. Nadie más.
4. **Solo un settlement `confirmed` cuenta para los saldos.** Un `pending` o `rejected`
   no altera ninguna deuda ni ninguna sugerencia.
5. El creador puede **cancelar** su propia afirmación mientras siga `pending`.

La idempotencia estructural de ADR-0015 §5 (`settlementId` + `from‖to‖transferIndex`) se
mantiene sobre la **creación**: reintentar la creación del mismo settlement no duplica.
Las transiciones (`confirm`/`reject`/`cancel`) son idempotentes por (ADR-0012).

## Consecuencias

- **Superficie HTTP nueva** (a especificar en el scope): crear afirmación, confirmar,
  rechazar, cancelar, y listar pendientes. El POST "registrar directo" de ADR-0016 §c
  **queda retirado** (ya hecho en PR #31, commit `a50ed45`).
- **Notificación** a la contraparte cuando hay un `pending` que le toca resolver (encaja
  con el outbox pendiente; ver bead `8hn`, que además pide 1 outbox + 1 notificación).
- **Estado nuevo** en el modelo y en el esquema (`status: pending|confirmed|rejected`).
- El motor de saldos (bead `xsx`) debe restar **solo** los settlements `confirmed`.
- **No-repudio**: cada transición registra quién la hizo (actor del JWT).

## Alcance / diseño

El diseño detallado (máquina de estados, endpoints, contrato HTTP, tratamiento de saldos,
notificación y preguntas abiertas) vive en `docs/design/settle-confirmacion-scope.md` y
**necesita aprobación de Andrea antes de codificar** (design-first, constitution §2).

## Firma

Decisión de producto de Andrea; transcrita por Claude. **Pendiente de su visto bueno
formal** (igual que ADR-0016).
