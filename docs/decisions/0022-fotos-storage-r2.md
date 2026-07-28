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
  devuelve la **URL PUT prefirmada** (una URL, no un envelope JSON). El dominio no la interpreta —
  la reenvía al cliente. Los **headers obligatorios** de la subida (Content-Type, Content-Length)
  los reporta la **ruta HTTP** (`FotoRoutes`), que ya conoce `contentType`/`sizeBytes`.

### La subida es un **presigned PUT** (R2 **no soporta POST**), firmando Content-Type + Content-Length

**Corrección (bead 7n3, hallazgo Codex P1, confirmado con la doc oficial de R2 vía Context7).** El
diseño inicial firmaba un **presigned POST Object** con una *policy* `content-length-range`. Pero
la doc de R2 es explícita:

> «R2 supports presigned URLs for **GET, HEAD, PUT, and DELETE** HTTP methods. **POST** requests
> for multipart form uploads **are not currently supported**.»
> — [developers.cloudflare.com/r2/api/s3/presigned-urls](https://developers.cloudflare.com/r2/api/s3/presigned-urls)

Es decir: **cada subida real por POST habría sido rechazada por R2** (los tests locales pasaban
porque solo validaban la estructura de la firma en local, sin tocar R2). El `content-length-range`
es exclusivo del POST policy, así que **no existe en un PUT**.

El adaptador real (`FotoStorageR2`, en `TripSquadService` porque hace HTTP/crypto —
infraestructura, no dominio — igual que `EstructuradorConfirmacionDeepSeek`) firma ahora la subida
como una **URL PUT prefirmada SigV4 (auth en query)** contra
`https://<accountId>.r2.cloudflarestorage.com/<bucket>/<key>`, con:

- `X-Amz-SignedHeaders=content-length;content-type;host` — **firma `Content-Type` y
  `Content-Length` (= `sizeBytes` exacto)** además de `host`. R2 **valida la firma recomputándola
  con los headers reales de la request**, así que el cliente **DEBE enviar ese Content-Type y ese
  Content-Length exactos** o la firma no valida (403). R2 **documenta explícitamente** la
  restricción de Content-Type en presigned PUT («the client must include a matching Content-Type
  header»); el Content-Length se impone por la **validación de firma SigV4 estándar** sobre los
  signed headers (mismo mecanismo, no una feature especial de R2).
- `X-Amz-Expires` = caducidad real; payload `UNSIGNED-PAYLOAD`; derivación de clave estándar
  (`kDate→kRegion→kService→kSigning`), verificada contra la doc real de R2/SigV4 vía Context7
  (constitución: ningún API sin su doc real).

**Qué impone R2 vs. qué impone la capa app (importante — no se finge un cap que R2 no da):**

- **R2 impone (por la firma):** el tamaño subido es **EXACTAMENTE `sizeBytes`** y el Content-Type
  es exactamente el declarado. No hay un «rango ≤ N» en un PUT (eso era el POST policy).
- **La capa app impone el techo de 20 MB, ANTES de firmar:** `CasosDeUsoFoto.presignSubida` rechaza
  `> 20 MB` con **422 `size_invalido`**, y el `sizeBytes` es **obligatorio** en el DTO (**422
  `missing_size_bytes`** si falta). `FotoStorageR2.urlDeSubida` **vuelve a rechazar** (throw
  `ErrorFotoStorageR2.tamanoInvalido`) si `sizeBytes ≤ 0` o `> maxBytes`, como **defensa en
  profundidad** — nunca firma una subida por encima del tope (no se puede «recortar» un
  Content-Length exacto). Combinado: el cliente no puede declarar > 20 MB (app 422) y no puede
  subir más de lo declarado (R2 exige el tamaño exacto firmado).

- **Lectura:** `urlDeLectura` devuelve una **URL GET prefirmada** (auth en query, `X-Amz-Expires`
  = caducidad real). Sin cambios (R2 soporta GET prefirmado).
- **Borrado real:** `borrar` firma un **DELETE prefirmado** y lo ejecuta vía `AsyncHTTPClient`
  (2xx o 404 = éxito idempotente). La ejecución HTTP se abstrae tras `ClienteHTTPR2` para poder
  testear sin red (mismo patrón que `ClienteHTTPDeepSeek`). Sin cambios (R2 soporta DELETE prefirmado).

### Contrato de subida hacia el cliente

`POST .../photos/presign` responde `{photoId, uploadUrl, uploadMethod:"PUT", uploadHeaders:{Content-Type,
Content-Length}, expiresIn}`. El cliente hace **`PUT uploadUrl`** con **esos headers exactos** y el
binario como cuerpo. (Antes se devolvía un envelope `{url, fields}` para un multipart **POST**; se
sustituye porque R2 no soporta POST.)

### Credenciales por entorno + wiring GATED

El adaptador real **nunca** se wirea por defecto. `main.swift` solo lo activa si están **todas**
las variables de entorno; si falta cualquiera, cae al stub (mismo comportamiento que en tests):

- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY`, `R2_SECRET`, `R2_BUCKET` (obligatorias), `R2_REGION`
  (opcional, default `auto`).

El **stub sigue siendo el default en tests**; `FotoStorageR2` **no se instancia con red en
tests** — los tests inyectan credenciales falsas + una hora fija y comprueban solo la estructura
de la firma/policy.

## Alternativas consideradas

- **Presigned POST + policy `content-length-range`** (el diseño inicial) — **imposible en R2**: R2
  **no soporta POST** (solo GET/HEAD/PUT/DELETE), así que cada subida real habría sido rechazada.
  Descartada por la doc oficial (ver arriba). Era, además, la única forma de imponer un **rango**
  `≤ N` en el borde; al no existir POST, ese rango exacto no está disponible en R2.
- **Presigned PUT firmando solo `host`** (sin acotar tamaño en la firma) — descartada: dejaría el
  Content-Length totalmente libre; el cliente podría subir un binario arbitrariamente grande. Se
  firma `Content-Length` (exacto) para que R2 lo exija, y el techo de 20 MB queda en la capa app.
- **Presigned PUT firmando `Content-Type` + `Content-Length` (elegida)** — un PUT con
  `UNSIGNED-PAYLOAD` no acota el rango, pero **firmar el `Content-Length` exacto** obliga a que el
  binario subido tenga ese tamaño (R2 valida la firma con el header real). No es un «rango ≤ 20 MB»
  (eso solo lo daba el POST policy que R2 no soporta), pero combinado con el **rechazo 422 en la
  capa app antes de firmar** (`sizeBytes > 20 MB`) acota el tamaño de forma real y honesta.
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
- **CORS del bucket:** el presigned **PUT** lo ejecuta el cliente (app), así que el bucket necesita
  una regla CORS que permita **PUT** (con los headers `Content-Type` y `Content-Length`) desde el
  origen de la app — configuración operativa del bucket, fuera del código.
- **Nueva dependencia declarada:** `swift-crypto` (Apple) en `TripSquadService`, para HMAC-SHA256 /
  SHA256 de SigV4 (portable a Linux/Render). Ya estaba en el grafo transitivo vía `jwt-kit`; se
  declara explícita para poder `import Crypto`. No añade proveedor ni red nuevos.
- **`TripSquadExpenses` sigue puro:** el cambio de puerto no le añade infraestructura; el adaptador
  real vive en `TripSquadService`.
- El cambio de firma del puerto es **retrocompatible en semántica de dominio**: `Foto.sizeBytes`
  sigue siendo `Int64?` (una fila legada podría no tenerlo); lo que cambia es que el **presign**
  exige el tamaño para poder acotar la subida.
