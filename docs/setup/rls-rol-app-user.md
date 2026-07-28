# Rol `app_user` para la RLS en producción (item 3, ADR-0030)

> Prerrequisito operativo para activar la RLS A+B (ADR-0030, bead 5n3) en producción.
> La migración `0014_rls_mecanismo.sql` crea el rol `authenticated` (sin `BYPASSRLS`) y las
> policies. Falta el rol de LOGIN con el que el servicio se conecta, que **asume**
> `authenticated` por transacción vía `enTransaccionConRol`.

## Por qué

El servicio NO pasa por PostgREST: se conecta con un rol propio. Para que las policies
por-usuario se evalúen, el helper `enTransaccionConRol(actor:)` hace, por transacción,
`SET LOCAL role = 'authenticated'` + `set_config('request.jwt.claims', '{"sub":<userId>}')`.
Para poder hacer `SET ROLE authenticated`, el rol de conexión debe ser **miembro** de
`authenticated`. Y **nunca** debe tener `BYPASSRLS` (si no, la RLS queda inerte).

## SQL a ejecutar (una vez, como superusuario / en el editor SQL de Supabase)

> ⚠️ **La contraseña debe ser URL-safe** (P2 Codex #61). El servicio construye la conexión
> parseando `DATABASE_URL` con `URLComponents` (ver `configPostgres` en `main.swift`). Si la
> contraseña lleva caracteres reservados de URI (`#`, `/`, `?`, `@`, `:`, `%`), `URLComponents`
> NO parsea el host y el servicio cae **en silencio** a los defaults (`PG*`/localhost) → no
> conecta a tu BD. Usa una contraseña **sin esos caracteres**, o **percent-encódéala** antes de
> ponerla en `DATABASE_URL` (p. ej. `#` → `%23`, `/` → `%2F`, `@` → `%40`).

```sql
-- 1. Rol de conexión del servicio. LOGIN, sin BYPASSRLS, sin superuser.
--    Cambia la contraseña por una fuerte y URL-safe (ver aviso de arriba); guárdala en el
--    gestor de secretos (NO en git).
create role app_user with login password '<PON_UNA_CONTRASEÑA_FUERTE_URL_SAFE>' nobypassrls noinherit;

-- 2. Puede asumir 'authenticated' (creado por la migración 0014) → SET ROLE authenticated.
grant authenticated to app_user;

-- 3. Conexión a la base.
grant connect on database postgres to app_user;   -- ajusta el nombre de la BD si aplica

-- 4. (Defensa) NUNCA concedas BYPASSRLS ni superuser a app_user. Verifícalo:
--    select rolname, rolbypassrls, rolsuper from pg_roles where rolname in ('app_user','authenticated');
--    Ambos deben tener rolbypassrls=f y rolsuper=f.
```

> **Supabase:** si usas el Postgres gestionado de Supabase, ejecuta esto en el **SQL Editor**
> con el rol `postgres`. El rol `authenticated` ya existe en Supabase; el `grant authenticated
> to app_user` sigue valiendo. Asegúrate de que la cadena `DATABASE_URL` del servicio en Render
> usa `app_user`, **no** `postgres` ni `service_role` (esos hacen bypass de RLS).

## Checklist de activación

- [ ] Ejecutar el SQL de arriba (rol `app_user`, sin BYPASSRLS, miembro de `authenticated`).
- [ ] `DATABASE_URL` en Render apunta a `app_user` (no `postgres`/`service_role`).
- [ ] El esquema `private` **nunca** se expone en `PGRST_DB_SCHEMAS` ni en el search_path de la API.
- [ ] **Bloqueante de código (bead pendiente):** enrutar TODAS las lecturas/escrituras por-usuario
      de los repos Postgres por `enTransaccionConRol` **antes** de conectar como `app_user` — hoy
      solo lo hacen las 3 escrituras de gastos; el resto conecta como el rol de la cadena y, si ese
      rol es `app_user` sin el wrapper, las policies negarían todo (o, si el rol tuviera BYPASSRLS,
      la RLS sería inerte). Ver bead de enrutado.
- [ ] Revisar los `GRANT` de `authenticated` sobre `public` (SELECT/INSERT/UPDATE/DELETE) contra
      mínimo privilegio al cerrar el modelo de datos.
```
