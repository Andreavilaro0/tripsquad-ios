# ADR-0022 — Fotos: puerto de storage + proveedor real (Cloudflare R2)

- **Fecha:** 2026-07-28
- **Estado:** accepted (parte de proveedor y puerto). El diseño del módulo M7 (metadatos,
  autorización, ciclo `pending`→`ready`) se decidió antes como borrador en
  `docs/design/fotos-plan-stub.md` / `docs/design/fotos-scope.md`; este ADR fija lo que quedaba
  abierto: **qué proveedor** y **cómo se impone el tope de tamaño**.
- **Dueña:** Andrea
- **Depende de:** ADR-0009 (Clean Architecture / servicio monolito modular), ADR-0018 (rol
  "owner ligero", usado por el borrado), ADR-0014 (invalidación de membresía).
- **Diseño de referencia:** `docs/design/fotos-plan-stub.md`, `docs/design/fotos-scope.md`.
- **Beads:** `7n3` (adaptador real), `8fd` (puerto recibe `sizeBytes`).

## Contexto

El módulo de fotos (M7) se construyó **contract-first con un stub**: un puerto `FotoStorage`
(en `TripSquadExpenses`, la única frontera con el object storage), `FotoStorageStub` como
implementación determinista sin red para dev/tests, y el proveedor real **aplazado a propósito**
("proveedor por decidir" en `fotos-scope.md`).

El puerto original era:

```swift
func urlDeSubida(storageKey: String, contentType: String, expiraEn: TimeInterval) async throws -> String
```

Con dos huecos que impedían pasar a producción:

1. **El tope de 20 MB (`fotos-scope.md`) era inaplicable.** El puerto NO recibía el tamaño, así
   que la validación de tamaño del caso de uso era opcional y, aun cuando se declaraba, **no se
   propagaba a ninguna firma** — el storage no podía rechazar una subida mayor que el tope. Un
   cliente malicioso podía subir un binario arbitrariamente grande al obtener una URL de subida.
2. **No existía adaptador real.** Sin proveedor elegido, `urlDeSubida`/`urlDeLectura`/`borrar`
   no hacían nada real (URLs `stub://`).

## Decisión

### Proveedor: Cloudflare R2 (DECISIÓN de Andrea, 2026-07-28)

El object storage de fotos es **Cloudflare R2**. R2 habla el protocolo **S3 con AWS Signature
Version 4 (SigV4)**, así que el adaptador es un cliente S3 SigV4 apuntado al endpoint de R2
(`https://<accountId>.r2.cloudflarestorage.com/<bucket>/<key>`, path-style, región `auto`).

### Puerto: `urlDeSubida` recibe `sizeBytes` (bead 8fd)

El puerto pasa a exigir el tamaño declarado:

```swift
func urlDeSubida(storageKey: String, contentType: String, sizeBytes: Int, expiraEn: TimeInterval) async throws -> String
```

- `sizeBytes` es **OBLIGATORIO** en el DTO del presign HTTP: ausente → **422 `missing_size_bytes`**
  (mismo criterio que los demás 422 de validación del contrato). Sin tamaño no se puede acotar la
  subida.
- `CasosDeUsoFoto.presignSubida` pasa de `sizeBytes: Int64?` a `Int64` no-opcional (validado
  `> 0` y `≤ 20 MB` → `reglaViolada("size_invalido")`) y lo **propaga hasta el puerto**.
- El `String` devuelto es **opaco** para el dominio: el stub devuelve `stub://…`; el adaptador R2
  devuelve el **descriptor JSON de un presigned POST** (endpoint + campos de formulario). El
  dominio no lo interpreta — lo reenvía al cliente, que ejecuta la subida.

### El cap se impone con un **presigned POST + policy `content-length-range`**

El adaptador real (`FotoStorageR2`, en `TripSquadService` porque hace HTTP/crypto —
infraestructura, no dominio — igual que `EstructuradorConfirmacionDeepSeek`) firma la subida como
un **presigned POST de S3/R2**, cuya *policy* incluye la condición:

```json
["content-length-range", 0, <min(sizeBytes, 20 MB)>]
```

**Este es el mecanismo que DE VERDAD impone el tope:** R2 **rechaza en el borde** (sin que el
binario llegue a nuestro back) cualquier subida cuyo `Content-Length` exceda el rango firmado.
La policy también fija el `Content-Type` y la **caducidad real** (`expiration` ISO-8601 =
`ahora + expiraEn`). La firma SigV4 del POST es `hex(HMAC-SHA256(signingKey, base64(policy)))`,
con la derivación de clave estándar (`kDate→kRegion→kService→kSigning`), verificada contra doc
real de SigV4 vía Context7 (constitución: ningún API sin su doc real).

- **Lectura:** `urlDeLectura` devuelve una **URL GET prefirmada** (auth en query, `X-Amz-Expires`
  = caducidad real).
- **Borrado real:** `borrar` firma un **DELETE prefirmado** y lo ejecuta vía `AsyncHTTPClient`
  (2xx o 404 = éxito idempotente). La ejecución HTTP se abstrae tras `ClienteHTTPR2` para poder
  testear sin red (mismo patrón que `ClienteHTTPDeepSeek`).

### Credenciales por entorno + wiring GATED

El adaptador real **nunca** se wirea por defecto. `main.swift` solo lo activa si están **todas**
las variables de entorno; si falta cualquiera, cae al stub (mismo comportamiento que en tests):

- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY`, `R2_SECRET`, `R2_BUCKET` (obligatorias), `R2_REGION`
  (opcional, default `auto`).

El **stub sigue siendo el default en tests**; `FotoStorageR2` **no se instancia con red en
tests** — los tests inyectan credenciales falsas + una hora fija y comprueban solo la estructura
de la firma/policy.

## Alternativas consideradas

- **Presigned PUT** (una sola URL, `Content-Length`/`x-amz-content-sha256` firmados) — descartada
  como mecanismo de cap: un PUT prefirmado con `UNSIGNED-PAYLOAD` **ignora el tamaño**, y firmar
  un `Content-Length` exacto obliga a un tamaño exacto (no un rango) y no es el mecanismo que S3/R2
  ofrece para acotar un rango. El **presigned POST con `content-length-range`** es la vía correcta
  para imponer "≤ 20 MB" en el borde.
- **Supabase Storage** — ya usamos Supabase para auth (JWKS, ADR-0014). Descartada frente a R2 por
  decisión de Andrea (coste de egreso cero de R2, y mantener el storage de binarios desacoplado
  del proveedor de identidad). El puerto permite cambiar de idea sin tocar dominio.
- **AWS S3** — mismo protocolo (SigV4), pero con coste de egreso; R2 lo evita. El adaptador es
  reutilizable contra S3 casi sin cambios si se reconsidera.
- **Subir el binario a través de nuestro back** (proxy) — descartada: el binario nunca debe pasar
  por el servicio (coste de ancho de banda y memoria); presign delega la transferencia
  cliente↔storage directamente.

## Consecuencias

- **Andrea debe crear, antes de activar en producción:** el bucket de R2, un API token S3 con
  permiso de lectura/escritura/borrado sobre ese bucket, y configurar `R2_ACCOUNT_ID` /
  `R2_ACCESS_KEY` / `R2_SECRET` / `R2_BUCKET` en el entorno de despliegue (Render). Mientras no
  estén, fotos funciona con el stub (sin binarios reales).
- **CORS del bucket:** el presigned POST lo ejecuta el cliente (app), así que el bucket necesita
  una regla CORS que permita POST desde el origen de la app — configuración operativa del bucket,
  fuera del código.
- **Nueva dependencia declarada:** `swift-crypto` (Apple) en `TripSquadService`, para HMAC-SHA256 /
  SHA256 de SigV4 (portable a Linux/Render). Ya estaba en el grafo transitivo vía `jwt-kit`; se
  declara explícita para poder `import Crypto`. No añade proveedor ni red nuevos.
- **`TripSquadExpenses` sigue puro:** el cambio de puerto no le añade infraestructura; el adaptador
  real vive en `TripSquadService`.
- El cambio de firma del puerto es **retrocompatible en semántica de dominio**: `Foto.sizeBytes`
  sigue siendo `Int64?` (una fila legada podría no tenerlo); lo que cambia es que el **presign**
  exige el tamaño para poder acotar la subida.
