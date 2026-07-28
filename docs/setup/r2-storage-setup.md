# Storage de fotos en Cloudflare R2 — setup (item 3, ADR-0022, bead 7n3)

> El adaptador `FotoStorageR2` (mergeado en develop, PR #60) firma peticiones **S3 SigV4**
> con Access Key + Secret. Está **GATED**: solo se activa si las 4 env vars están presentes;
> por defecto el servicio usa `FotoStorageStub`. Este doc es lo que Andrea ejecuta en sus
> cuentas (Cloudflare + Render) para encenderlo.

## ❗ Token correcto: R2 API token, NO Account API token

La subida usa el protocolo **S3 (SigV4)**, que necesita un **Access Key ID + Secret Access
Key**. Eso lo da el flujo **R2 API tokens**, no el de "Account API tokens" (permission groups
→ Bearer token, que es para la API REST de Cloudflare y **no** sirve aquí).

## Pasos

1. **Crear el bucket.** Barra lateral → **R2** → **Create bucket** → nombre `tripsquad-fotos`
   (o el que prefieras). Región/jurisdicción según dónde quieras los datos (UE si RGPD aprieta).
2. **Crear el R2 API token.** R2 → **Overview** → arriba a la derecha **"Manage R2 API Tokens"**
   → **Create API token**:
   - **Permissions: `Object Read & Write`** (cubre GET presign, PUT presign y DELETE que usa el
     adaptador).
   - **Specify bucket(s): Apply to specific buckets only → `tripsquad-fotos`** (mínimo privilegio).
   - Crear. Cloudflare muestra **una sola vez** el Secret — cópialo ya.
3. **Regla CORS del bucket.** R2 → bucket → **Settings → CORS policy**. El cliente sube por
   **PUT presignado** con headers `Content-Type` y `Content-Length`. Ejemplo mínimo:
   ```json
   [
     {
       "AllowedOrigins": ["https://<origen-de-tu-app>"],
       "AllowedMethods": ["PUT", "GET"],
       "AllowedHeaders": ["Content-Type", "Content-Length"],
       "MaxAgeSeconds": 3600
     }
   ]
   ```
4. **Env vars en Render** (servicio TripSquad, variables secretas — NUNCA en git):

   | Variable | De dónde sale |
   |---|---|
   | `R2_ACCOUNT_ID` | el `<xxx>` del endpoint `https://<xxx>.r2.cloudflarestorage.com` (tu Account ID) |
   | `R2_ACCESS_KEY` | Access Key ID del token R2 |
   | `R2_SECRET` | Secret Access Key del token R2 |
   | `R2_BUCKET` | `tripsquad-fotos` |
   | `R2_REGION` | *(opcional)* por defecto `auto` |

   Con las 4 presentes, `main.swift` wirea `FotoStorageR2`; si falta cualquiera, sigue con el stub.

## Verificación tras encender

- El endpoint `POST /trips/:id/photos/presign` devuelve
  `{photoId, uploadUrl, uploadMethod:"PUT", uploadHeaders:{Content-Type, Content-Length}, expiresIn}`.
- El cliente hace `PUT uploadUrl` con esos headers **exactos** (si difieren, R2 devuelve 403 por
  firma inválida — es el enforcement del tamaño: el `Content-Length` va firmado).
- Fotos > 20 MB se rechazan con **422** en la capa app antes de firmar (tope duro).

## Seguridad

- El Secret solo en Render (secreto). Si se filtra (chat, logs), **rótalo** desde Manage R2 API
  Tokens.
- Token scopeado al bucket y a `Object Read & Write` — sin acceso a otros buckets ni a la cuenta.
