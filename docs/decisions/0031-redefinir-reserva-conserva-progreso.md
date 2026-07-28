# ADR-0031 — Redefinir un reservable conserva el progreso de reserva (bead 9bz)

- **Estado:** accepted (decisión delegada a Claude por Andrea, 2026-07-28: "acábalo tú y decide").
- **Aclara / precisa:** ADR-0024 (reservas por persona) §comportamiento de `definir`. Append-only: no
  edita el 0024; fija el comportamiento que 0024 dejó como pregunta abierta (follow-up 9bz).

## Contexto

`CasosDeUsoReserva.definir` usa `repo.upsert`, y construía siempre los estados nuevos en
`.pendiente`. Al redefinir un reservable existente (p. ej. cambiar el `kind` de Vuelo a Tren, o
añadir un participante), **se borraba el `.reservado` de todos**: quien ya había marcado su
reserva volvía a `.pendiente`. El follow-up 9bz pedía confirmar si ese reseteo era el
comportamiento querido.

## Decisión

**Redefinir CONSERVA el progreso.** `definir` lee la reserva previa y arrastra el estado de los
participantes que siguen en la nueva definición:

- **`cadaUnoElSuyo`:** cada participante que sigue conserva su estado (`.reservado`/`.pendiente`);
  los participantes NUEVOS arrancan `.pendiente`. Quien sale de la definición pierde su estado
  (ya no forma parte).
- **`unoParaTodos`:** se conserva el estado solo si el modo sigue siendo `unoParaTodos` y el
  **responsable no cambia**. Si cambia el responsable (o el modo), se arranca `.pendiente` —
  porque "quién reservó" ya no aplica al mismo actor.

## Consecuencias

- **A favor:** lo menos sorprendente para el usuario — editar los detalles de un reservable (kind,
  añadir gente) no borra el trabajo ya hecho por el grupo.
- **En contra / límite:** un cambio de modo o de responsable sí resetea, a propósito (el estado
  previo ya no tiene sentido). Documentado arriba.
- Sin cambio de esquema: el merge ocurre en el caso de uso antes del `upsert`. El adaptador
  Postgres y el en-memoria no cambian su contrato.
