# ADR-0032 — Control de concurrencia: merge servidor sin conflicto cuando los campos no solapan (bead 7yy)

- **Estado:** accepted (decisión delegada a Claude por Andrea, 2026-07-28: "acábalo tú y decide").
- **Firma** la recomendación del doc decision-ready `docs/design/concurrencia-etag-campo-vs-fila-7yy.md`
  (Opción B). Relacionado: ADR-0013 §3 (criterio de activación de CRDTs), ADR-0015 §15 (versionado
  por campo). Append-only: no edita esos ADR.

## Contexto

ADR-0015 §15 paga versionado por CAMPO (prep CRDT, ADR-0013 §3), pero el control de concurrencia
sigue siendo `If-Match` al ETag de la FILA entera. Si Iván cambia la categoría y Marta el importe
(campos distintos, sin solape), el segundo recibe **conflicto falso** aunque no haya colisión
real. Esos 412 espurios inflan la señal del 2 % que dispara CRDTs (ADR-0013 §3) — se podrían
encender CRDTs (que los gastos explícitamente NO quieren) por un artefacto de medición.

## Decisión

**Opción B — inteligencia de conflicto en el servidor, reusando `expense_revisions`:**

- El cliente sigue mandando `If-Match` con el ETag de la FILA (contrato sin cambios para el cliente).
- Cuando el ETag no coincide, el servidor NO devuelve 412 a ciegas: compara los CAMPOS que cambian
  esta edición contra los que cambiaron desde el ETag base (vía `expense_revisions`, el historial
  append-only que ya se guarda). **Si los conjuntos de campos NO solapan, hace merge y acepta**
  (nuevo ETag); si solapan, devuelve el 409/412 con conflicto explícito.
- **El dinero conserva el conflicto explícito** (ADR-0013 §3): si dos ediciones tocan el importe,
  NO se auto-mergea — el usuario decide. La inteligencia solo evita el conflicto FALSO entre campos
  disjuntos.

Descartadas: (A) ETag por campo (cambia el contrato del cliente y multiplica los ETags que viajan);
(C) statu quo (mantiene los conflictos falsos que ensucian la señal de CRDTs).

## Consecuencias

- **A favor:** desaparecen los conflictos falsos entre campos disjuntos; la señal de 412 vuelve a
  reflejar colisiones REALES, protegiendo el criterio de activación de CRDTs; el cliente no cambia.
- **En contra:** más lógica en el servidor en el camino de edición (comparar campos vs
  `expense_revisions`); hay que definir el conjunto de campos por edición.
- **Pendiente de implementación:** este ADR fija la dirección; el slice de código (comparación de
  campos en `actualizar`) es un bead aparte. Hoy sigue el If-Match por fila hasta implementarlo.
