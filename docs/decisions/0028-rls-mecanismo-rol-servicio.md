# ADR-0028 — Mecanismo de RLS bajo rol de servicio (SET LOCAL role + claims + funciones `private`)

- **Fecha:** 2026-07-28
- **Estado:** accepted
- **Firmado:** 2026-07-28 por Andrea (decisión directa del mecanismo A+B)
- **Dueña:** Andrea
- **Origen:** bead 5n3 (`TripSquad-iOS-5n3`), Codex voz externa #8
- **Cierra:** el PENDIENTE de `db/migrations/0001_expenses.sql:140-143` ("las políticas RLS… el mecanismo exacto se investiga antes de la primera escritura real")
- **Depende de / concreta:** ADR-0009 §6 (rol de servicio dedicado, grants mínimos, sin `service_role`), ADR-0014 §3 (recursión RLS, `SECURITY DEFINER` + `search_path=''`, `TO authenticated`, `NOBYPASSRLS`), ADR-0013 (paridad RLS↔sync-rules)
- **Material de soporte (ya NO pendiente):** `docs/design/rls-mecanismo-investigacion-5n3.md`

## Contexto

El servicio se conecta a Postgres con un **rol de aplicación propio y grants mínimos**
(ADR-0009 §6), no con el JWT del usuario final vía PostgREST. Las policies RLS estilo
Supabase por-usuario dependen del **rol activo** de la conexión y de
`current_setting('request.jwt.claims')` — ambos los fija PostgREST por petición. Nuestro
backend no pasa por PostgREST, así que, sin un mecanismo explícito:

- con un rol `BYPASSRLS` (p. ej. `service_role`), **las policies ni se evalúan** — RLS
  queda inerte como defensa en profundidad;
- con un rol normal sin fijar rol ni claims, `sub`/`auth.uid()` es NULL y toda policy de
  membresía **niega todo** — el servicio no podría ni leer ni escribir.

ADR-0014 §3 ya fijó los PRINCIPIOS (recursión, `SECURITY DEFINER`, `search_path=''`,
`TO authenticated`, rol de servicio `NOBYPASSRLS`), pero no el MECANISMO concreto ni había
ninguna policy en `db/migrations/*`. El doc de investigación 5n3 expuso las tres opciones
reales (A: emular PostgREST por transacción; B: funciones `security definer` en `private`;
C: barrera deny-all por-viaje) con doc de Postgres/Supabase traída vía Context7, y dejó la
decisión a Andrea.

## Decisión

Se adopta la combinación **A + B** del doc 5n3, con el rol de servicio **sin `BYPASSRLS`**.

**A — emular a PostgREST por transacción.** Todo camino de datos por-usuario se ejecuta en
una transacción que, antes de las queries, fija:

```sql
select set_config('role', 'authenticated', true),                 -- == SET LOCAL ROLE authenticated
       set_config('request.jwt.claims', '{"sub":"<userId>", ...}', true);
```

El `true` es transaction-local (`SET LOCAL`): se revierte al terminar la transacción, seguro
con conexiones pooled. En la capa de datos esto vive en un **helper único**
`PostgresClient.enTransaccionConRol(actor:)`
(`packages/TripSquadExpensesPostgres/.../RolRLS.swift`), difícil de olvidar: si un camino no
pasa por él, la RLS no filtra por usuario y hay fuga (aviso explícito del doc 5n3).

**B — membresía en funciones `security definer` del esquema `private`.** La identidad y la
membresía se resuelven en `private.uid()`, `private.es_miembro(trip,user)`,
`private.rol_en_viaje(...)` y las variantes por tabla-hija, todas con `set search_path=''` y
referencias `public.*` calificadas. Las policies las invocan, evitando la recursión RLS de
una policy sobre `trip_members` que consulta `trip_members`. El esquema `private` **nunca se
expone en la API** (no entra en `PGRST_DB_SCHEMAS`); `authenticated` recibe solo `USAGE` +
`EXECUTE`, revocado de `public`.

**Modelo de dos capas.** RLS es la **capa 2** Zero-Trust: barrera por-viaje y por-usuario —
quien asuma `authenticated` solo ve/escribe filas de viajes de los que el `sub` del claim es
**miembro activo**. Por eso las policies acotan por **membresía**, no por ownership: "todos
editan" dentro de un viaje (ADR-0015 §15) es válido, y el ownership fino (ETag, autor, viaje
cerrado) lo sigue haciendo la **capa 1** (el dominio `CasosDeUso*`, ya testeado). Tablas
por-usuario (`idempotency_keys`, `write_rejections`, `write_conflicts`) acotan por
`user_id = private.uid()`. `trips`/`trip_members` llevan policies de bootstrap (crear tu
propio viaje / auto-unirte por invitación).

La migración `db/migrations/0012_rls_mecanismo.sql` implementa todo lo anterior sobre **todas**
las tablas de datos existentes.

## Alternativas consideradas

- **Opción C (deny-all por-viaje, authz solo en app)** — RLS como red de seguridad que solo
  acota por `trip_id`, con la autoridad real en el dominio. Más barata en ceremonia, pero es
  una barrera **por-viaje**, no **por-identidad individual**: más débil como capa 2
  Zero-Trust. Se descarta como mecanismo principal; su espíritu (dominio = fuente de verdad
  fina) se conserva como capa 1.
- **`service_role` / rol con `BYPASSRLS`** — dejaría las policies inertes. Prohibido ya por
  la constitution y ADR-0009/0014.
- **`membership_version` u otra authz en el token** — rechazado en ADR-0014 §1: quedaría
  obsoleto justo en el caso que queremos matar (expulsión). La membresía se comprueba siempre
  contra `trip_members` en el momento de uso.
- **Depender de `auth.uid()` de Supabase** — se usa `private.uid()` propio (lee el mismo
  claim `sub`) para que la migración y los tests corran en un Postgres vanilla (CI/local) sin
  el esquema `auth`, manteniendo paridad: bajo PostgREST real, `request.jwt.claims` trae el
  mismo `sub`.

## Consecuencias

- **Todo camino de datos por-usuario debe ir por `enTransaccionConRol(actor:)`.** Se adopta
  ya en las escrituras de gastos (`RepositorioPostgres.guardar/actualizar/eliminar`) y se
  valida con test de contrato. **Follow-up (beads):** enrutar el resto de repos (chat,
  itinerario, reservas, votaciones, viaje, settlements) y los **caminos de LECTURA** por el
  mismo helper antes de que el servicio conecte como `authenticated` en producción; hasta
  entonces esos caminos usan el rol privilegiado y RLS los deja pasar por bypass.
- **Gates de ENTORNO para Andrea (fuera de la migración de esquema):**
  1. Crear el **rol de conexión de la app** (p. ej. `app_user`) **sin `BYPASSRLS`**,
     `LOGIN`, y **`GRANT authenticated TO app_user`** para que pueda `SET ROLE authenticated`.
  2. NO usar `service_role` ni ningún rol con `BYPASSRLS` para el servicio.
  3. Ajustar `search_path`/`PGRST_DB_SCHEMAS` para que `private` **jamás** se exponga.
  4. Revisar los `GRANT` a `authenticated` de la migración (SELECT/INSERT/UPDATE/DELETE en
     `public`) frente al principio de mínimo privilegio cuando el modelo esté completo.
- **Los tests de integración existentes no se rompen:** conectan como `postgres`
  (superusuario/dueño), que hace bypass de RLS; la barrera aplica a quien asuma
  `authenticated`.
- **Paridad RLS↔sync-rules (ADR-0013):** las mismas expresiones de membresía
  (`private.es_miembro`) deben alimentar las sync-rules de PowerSync; queda como contrato
  vinculante a verificar cuando se conecte el sync.
- **Rendimiento (ADR-0014 §3):** las funciones de membresía se evalúan por fila; con los
  índices existentes (`idx_trip_members_member`, `expenses_trip_idx`, …) y, si hace falta,
  envolviendo llamadas en sub-selects cacheables, se mantiene aceptable. A vigilar al crecer.

## Fuentes (Context7 · doc real)

- Supabase — `private` schema + `security definer` + policies (RLS testing):
  `apps/docs/content/guides/local-development/testing/pgtap-extended.mdx`
- Supabase — `SECURITY DEFINER` debe fijar `search_path` (`= ''`, referencias calificadas):
  `apps/docs/content/guides/database/functions.mdx`
- Supabase — emulación de PostgREST: `set_config('role', …, true)` +
  `set_config('request.jwt.claims', …, true)`:
  `packages/pg-meta/src/sql/studio/role-impersonation.ts`
- Supabase — PostgREST asume el rol del claim vía `SET ROLE` (authenticator → authenticated):
  `docker/docker-compose.yml`
- Supabase — troubleshooting de tests con RLS (`set local role authenticated`,
  `request.jwt.claims`): `apps/docs/content/guides/local-development/testing/overview.mdx`
