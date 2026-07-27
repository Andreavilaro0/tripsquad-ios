# Investigación: mecanismo real de RLS con rol de servicio dedicado (bead 5n3)

> **Estado: BORRADOR DE INVESTIGACIÓN — decisión pendiente de Andrea.**
> Esto NO es un ADR. Es material de soporte para que Andrea dirija la decisión y
> firme el ADR que fije el mecanismo. La constitution reserva las decisiones de
> arquitectura/seguridad a Andrea; aquí solo se exponen las opciones reales, sus
> trade-offs (con doc de Postgres/Supabase traída vía Context7) y un test que lo
> demostraría. Referencias: ADR-0009 §6, `db/migrations/0001_expenses.sql:141-142`,
> Codex voz externa #8.

## El problema (por qué las RLS por usuario NO se evalúan solas aquí)

El servicio se conecta a Postgres con un **rol propio de aplicación, grants mínimos**
(ADR-0009 §6), no con el JWT del usuario final vía PostgREST. Las policies RLS de
Supabase por usuario dependen de `auth.uid()` / `auth.jwt()`, que a su vez leen
`current_setting('request.jwt.claims')` y del **rol activo** de la conexión. PostgREST
fija ambos por petición antes de ejecutar la query del usuario. Nuestro backend NO pasa
por PostgREST, así que:

- Si la conexión usa un rol con `BYPASSRLS` (como `service_role`), **las policies NI
  SIQUIERA se evalúan** — RLS queda inerte como defense-in-depth.
- Si usa un rol normal SIN fijar `request.jwt.claims` ni el rol por-usuario, `auth.uid()`
  devuelve NULL y cualquier policy `auth.uid() = user_id` **niega todo** — el servicio
  no podría ni leer ni escribir.

Conclusión: RLS como "capa 2 Zero-Trust" (ADR-0009 §4) exige **elegir y fijar** un
mecanismo explícito antes de la primera escritura real. Hoy no hay ninguna policy en
`db/migrations/*`; el comentario en `0001_expenses.sql:141` deja esta decisión abierta.

## Lo que hace PostgREST por dentro (referencia Context7)

Antes de la query del usuario, PostgREST ejecuta (equivalente):

```sql
select set_config('role', <rol_del_jwt>, true),          -- SET LOCAL role
       set_config('request.jwt.claims', <claims_json>, true);
```

`true` = transaction-local (`SET LOCAL`): se revierte al terminar la transacción, seguro
para conexiones pooled. Con eso, `auth.uid()` (que lee `request.jwt.claims ->> 'sub'`)
funciona dentro de las policies. (Fuente: `role-impersonation.ts` de Supabase Studio,
que emula exactamente este flujo.)

## Opciones reales

### Opción A — Emular a PostgREST por transacción (`SET LOCAL role` + claims)
Cada request del servicio abre transacción y hace `SET LOCAL role = 'authenticated'` +
`set_config('request.jwt.claims', jsonb con sub=userId, true)`. Las policies existentes
"estilo Supabase" (`auth.uid() = user_id`, membresía) se evalúan igual que si viniera de
PostgREST. Los clientes offline (PowerSync sync-rules) comparten la MISMA lógica → paridad
RLS↔sync-rules (ya prometida en ADR-0009 §"suite de contrato").
- **A favor:** policies idénticas para servidor y clientes; RLS realmente activa por
  usuario; el rol de app NO necesita `BYPASSRLS`.
- **En contra:** todo camino de datos debe ir en transacción con el `SET LOCAL` (fácil de
  olvidar → fuga si falta); el rol de app debe poder `SET ROLE authenticated`.

### Opción B — Funciones `security definer` en esquema `private` + policies que las usan
Las comprobaciones de membresía viven en `private.get_user_trip_role(trip, user)` etc.
(`security definer`, `set search_path=''`), y las policies las invocan. Evita la recursión
RLS (una policy sobre `trip_members` que a su vez consulta `trip_members`). Sigue
necesitando fijar `request.jwt.claims` (combina con A para saber QUIÉN es el usuario).
- **A favor:** policies legibles, sin recursión; patrón oficial Supabase para RBAC.
- **En contra:** `security definer` mal expuesto = bypass de RLS (lint de Supabase
  `anon_security_definer_function_executable`); el esquema `private` NUNCA en API expuesta.

### Opción C — Authz solo en app + RLS "deny-all" como barrera entre viajes
El servicio autoriza en la capa de dominio (los `CasosDeUso*` ya lo hacen: membresía +
ownership, endurecidos en bead iou/TOCTOU). RLS se ENABLE en todas las tablas pero el rol
de app NO recibe policies que lo habiliten para saltar entre viajes: se le dan grants por
columnas/tablas y las policies acotan por `trip_id` presente en un `SET LOCAL
app.current_trip`/claim. Es defense-in-depth pura: si un bug de dominio filtra un `trip_id`
ajeno, Postgres corta.
- **A favor:** menos ceremonia por request; la autoridad real ya está en el dominio
  (testeado); RLS es red de seguridad, no la fuente de verdad.
- **En contra:** más débil como "capa 2 por usuario" (acota por viaje, no por identidad
  individual); hay que fijar igualmente algún `current_setting` de contexto.

## Recomendación TENTATIVA (para que Andrea decida, no decidida)

**A + B combinadas**, sin `BYPASSRLS` en el rol de app:
1. Rol de app normal (sin bypass) con `GRANT` mínimos y permiso para `SET ROLE authenticated`.
2. Middleware de datos: toda escritura/lectura de usuario en transacción con
   `SET LOCAL role = authenticated` + `set_config('request.jwt.claims', …)` (Opción A).
3. Membresía vía `private.*` `security definer` con `search_path=''`, nunca en schema
   expuesto (Opción B), y policies por tabla que las usan.
4. **Paridad**: las mismas expresiones alimentan las sync-rules de PowerSync (contrato
   ADR-0009 §"suite de contrato verifica paridad RLS↔sync-rules").

Encaja con lo ya construido: la autoridad de dominio (los `CasosDeUso*`) queda como capa 1;
RLS por-usuario real como capa 2 Zero-Trust, no como mero deny-all.

## Test que lo demostraría (criterio de aceptación de 5n3)

Test de integración contra Postgres real (mismo harness que `integration`/testcontainers):
1. Sembrar viaje T con miembros {ana, ivan} y un gasto de ana.
2. Con `SET LOCAL role=authenticated` + claims `sub=sara` (NO miembro), un `SELECT`/`UPDATE`
   directo del gasto de T **devuelve 0 filas / falla la policy** — aunque el rol de app
   tenga grant sobre la tabla.
3. Con claims `sub=ivan` (miembro pero no autor), `SELECT` ve el gasto (miembro) pero
   `DELETE`/`UPDATE` del gasto ajeno lo corta la policy de ownership.
4. Con claims `sub=ana`, la operación pasa.
5. Aserción clave: el rol de app **no** tiene `rolbypassrls` (`SELECT rolbypassrls FROM
   pg_roles WHERE rolname = current_user` = false), garantizando que las policies se evalúan.

Esto demuestra RLS "por usuario" viva bajo el rol de servicio, cerrando el criterio de 5n3.

## Preguntas abiertas para Andrea
- ¿RLS por-usuario individual (A+B) o barrera por-viaje (C) para el MVP? (coste/ceremonia
  vs. profundidad Zero-Trust).
- ¿El rol de app hace `SET ROLE authenticated`, o creamos un rol `app_user` propio con
  policies a medida (sin depender de los roles Supabase)?
- ¿Se fija el ADR ahora (antes de la primera escritura real) o se congela A+B como default
  y se detalla al conectar el primer endpoint de escritura a Postgres?
