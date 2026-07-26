# ADR-0027 — Historial de ediciones (lectura) y derecho al olvido RGPD: hard-delete, no crypto-shredding

- **Fecha:** 2026-07-27
- **Estado:** accepted
- **Dueña:** Andrea
- **Origen:** beads `p4b` (historial de ediciones) y `o1v` (crypto-shredding
  cross-user en `expense_revisions`, voz externa Gemini ronda 2)
- **Enmienda a:** ADR-0015 §15 ("Permisos de edición: todos editan, todo queda
  registrado"), ADR-0013 §5 (tombstones y crypto-shredding)

> Los ADR anteriores **no se editan** (regla 4 de la constitution: append-only).
> Este ADR los enmienda por escrito. Donde este documento y uno anterior
> discrepan, manda este.

## Contexto

ADR-0015 §15 diseñó `expense_revisions` (append-only) y, para el derecho al
olvido, propuso **crypto-shredding con la clave del GASTO**: cifrar
`old_value`/`new_value` de texto libre con esa clave y borrarla para "olvidar".

La voz externa Gemini (ronda 2, bead `o1v`) encontró el hueco: con "todos
editan" (ADR-0015 §15), una revisión de `expense_revisions` puede tener
`edited_by` distinto del dueño del gasto (`expenses.paid_by`). Si Marta edita
la descripción de un gasto de Iván y luego Marta ejerce su derecho al olvido,
borrar la clave DEL GASTO —única forma de olvidar el texto de Marta con ese
diseño— **rompe el acceso de Iván a su propio dato**. El derecho al olvido de
un tercero no puede destruir datos del propietario.

Además faltaba, sin más bead que este, la mitad **lectura** de p4b:
`expense_revisions` existía y se escribía (`RepositorioPostgres.actualizar`),
pero no había puerto ni ruta para leerla, y el doble en memoria
(`RepositorioEnMemoria`) ni siquiera registraba revisiones — un test contra el
doble no podía detectar una regresión aquí (mismo patrón de "el doble no debe
mentir" que causó el agujero de `CasosDeUsoVotacion.cerrar`, ADR-0015 doc raíz).

## Decisión

**DECISIÓN de Andrea, 2026-07-27: NO se diseña crypto-shredding.** El derecho
al olvido de `expense_revisions` se ejerce con **hard-delete selectivo por
autor**:

```sql
DELETE FROM expense_revisions WHERE edited_by = <user_id>;
```

Esto sustituye, para `expense_revisions`, el mecanismo de "clave por gasto +
borrar la clave" de ADR-0015 §15 / ADR-0013 §5. Las razones:

- **Es selectivo por AUTOR, no por gasto.** Borra el rastro de texto libre de
  UN actor sin tocar los gastos que edita (son de OTRO dueño) ni las
  revisiones de otros autores sobre el mismo gasto. Resuelve exactamente el
  hallazgo de Gemini: el olvido de Marta nunca puede destruir el dato de Iván,
  porque no toca la fila `expenses` ni las revisiones `edited_by != Marta`.
- **Es GLOBAL, no por viaje.** El derecho al olvido es de la CUENTA
  (`edited_by = user_id`), no de un `trip_id` — un `DELETE` sin filtro de viaje
  cubre todas las ediciones de ese usuario en todos los viajes de una vez.
- **No se diseña jerarquía de claves.** Codex había señalado (P2, ronda previa)
  que el crypto-shredding de ADR-0015 §15 estaba "nombrado, no diseñado": faltaba
  jerarquía de claves, almacén, rotación, backup/restore y borrado transaccional.
  Diseñar eso para un caso que un `DELETE` resuelve directamente es
  sobre-ingeniería que Andrea decide no pagar.
- **Es la EXCEPCIÓN documentada al append-only** que ADR-0015 §15 ya preveía
  ("Excepción: el borrado por RGPD, ver más abajo"): un `DELETE` real, selectivo
  por `edited_by`, en vez de un `UPDATE` que reescribiera valores.

**Alcance de este ADR — también cierra la mitad lectura de p4b:**

- Puerto `GastoRepositorio` (`packages/TripSquadExpenses/.../Puertos.swift`)
  gana dos métodos: `revisiones(deGasto:en:limit:)` (lectura, paginada con el
  mismo clamp [1,200] default 50 que chat/settle/itinerario) y
  `olvidarRevisionesDe(_:)` (el hard-delete de este ADR, sin `tripId`).
  Implementados en `RepositorioPostgres` (JOIN con `expenses` para filtrar por
  `trip_id` en la lectura — defensa en profundidad, `expense_id` es una PK
  global de cliente) y en `RepositorioEnMemoria`.
- `RepositorioEnMemoria.actualizar` **ahora registra revisiones** (antes solo
  lo decía un comentario) — el doble no debe mentir respecto a producción; si
  no, `revisiones`/`olvidarRevisionesDe` no serían testeables sin Postgres.
- Ruta `GET /trips/:tripId/expenses/:id/revisions?limit=` — autorización
  `is_member(trip_id)` (la misma función única de ADR-0013 §4): CUALQUIER
  miembro ve el historial de CUALQUIER gasto, coherente con "todos editan" de
  ADR-0015 §15. Un `expenseId` inexistente o de otro viaje da el MISMO 403 que
  no-miembro (sin fuga de existencia, mismo criterio que el resto del módulo).
- `olvidarRevisionesDe(userId:)` es un caso de uso **invocable, sin endpoint
  HTTP público**: es un flujo administrativo de borrado de cuenta (RGPD), no
  una acción de un miembro sobre un viaje. Se engancha al flujo de borrado de
  cuenta el día que exista (fuera del alcance de este bead); hoy queda listo y
  testeado.

## Alternativas consideradas

- **Diseñar la jerarquía de claves de crypto-shredding por autor** (en vez de
  por gasto) — resolvería el hallazgo de Gemini sin abandonar crypto-shredding,
  pero paga el coste de diseño que Codex ya había señalado como pendiente
  (jerarquía, almacén, rotación, backup/restore, borrado transaccional) para un
  problema que un `DELETE` selectivo resuelve directamente. Descartada por
  sobre-ingeniería.
- **No tocar nada y dejar el crypto-shredding "nombrado" de ADR-0015 §15** —
  descartada: es el hallazgo P1 de Gemini, deja un RGPD roto (el olvido de un
  tercero destruiría datos del propietario) y bloqueaba p4b.

## Consecuencias

- `expense_revisions` deja de ser puramente append-only en el sentido estricto
  de ADR-0015 §15: admite `DELETE` selectivo por `edited_by`, la excepción que
  ese mismo ADR ya anticipaba para RGPD. Sigue sin admitir `UPDATE` nunca.
- El historial que ve un miembro tras el ejercicio del derecho al olvido de OTRO
  autor tiene un hueco silencioso en esa fila (desapareció, no se marca "editado
  por usuario borrado"): aceptable para este alcance; UI/copy de ese hueco queda
  fuera de este ADR.
- La granularidad campo-a-campo real de `field`/`old_value`/`new_value` (hoy
  `RepositorioPostgres.actualizar` escribe `field: 'expense'` con el JSON del
  reparto entero, no un diff por campo) **no se toca en este ADR** — es una
  mejora futura y un bead aparte; aquí solo se cierra lectura + RGPD sobre lo
  que YA se escribe.
- `RepositorioEnMemoria` y `RepositorioPostgres` quedan de nuevo en paridad de
  comportamiento observable para este flujo (el doble no miente).
