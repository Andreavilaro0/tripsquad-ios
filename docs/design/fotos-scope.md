# M7 — Fotos — Scope (BLOQUEADO: necesita decisión de storage)

> PROPUESTA. **NO construido en autónomo** porque requiere una **dependencia/servicio externo
> de almacenamiento de binarios + credenciales** — decisión de Andrea (muro duro). Aquí queda
> el diseño para que decidas.

## Idea
Álbum de fotos por viaje: subir, ver, borrar. El backend NO guarda los binarios en Postgres
(malo para blobs grandes); guarda **metadatos** y delega el binario a un **object storage**.

## MURO DURO — decisión de Andrea
**¿Dónde viven los binarios?** Opciones:
- **Cloudflare R2** (S3-compatible, sin egress fees) — recomendado por coste.
- **Supabase Storage** (ya usáis Supabase para auth → un proveedor menos).
- **AWS S3** (estándar, egress con coste).
Cada una = dependencia nueva + credenciales + posible coste. **No se puede elegir en autónomo.**

## Patrón seguro recomendado (presigned URLs)
El binario NO pasa por el backend (ahorra ancho de banda y memoria):
1. Cliente pide subir → `POST /trips/:tripId/photos/presign` {contentType, size} → backend valida
   (miembro, tamaño/tipo permitidos), genera un `storage_key`, devuelve una **URL prefirmada de
   subida** (PUT directo al storage) + el `photoId` pendiente.
2. Cliente sube el binario directo al storage con esa URL.
3. Cliente confirma → `POST /trips/:tripId/photos/:photoId/confirm` → backend marca la foto lista.
4. `GET /trips/:tripId/photos` → lista con URLs prefirmadas de **lectura** (temporales).

## Esquema (migración 0007, cuando se decida)
```sql
create table photos (
    id           text primary key,
    trip_id      text not null references trips(id),
    uploaded_by  text not null,
    storage_key  text not null,          -- ruta en el bucket
    content_type text not null,
    size_bytes   bigint,
    caption      text,
    status       text not null default 'pending' check (status in ('pending','ready')),
    created_at   timestamptz not null default now()
);
create index if not exists idx_photos_trip on photos (trip_id, created_at);
```

## Autorización
- Subir/ver/borrar: solo miembros (403 sin fuga). Borrar: subidor o owner. Límites de tipo
  (image/jpeg, image/png, image/heic) y tamaño (p.ej. 20 MB) validados en el presign.
- Las URLs prefirmadas caducan (p.ej. 15 min subida, 1 h lectura).

## Qué SÍ se podría construir sin decidir el storage (si Andrea quiere avanzar)
- El **puerto** `FotoStorage` (presignUpload/presignDownload/delete) + un **stub en-memoria/local**
  para tests, y toda la lógica de metadatos/autorización (dominio + Postgres de la tabla photos +
  endpoints), dejando el adaptador real (R2/Supabase/S3) para cuando se decida.
- **No lo hice** porque sin el proveedor elegido el adaptador real queda sin construir y el flujo
  no es probable de punta a punta; si prefieres que adelante el andamiaje (puerto + stub +
  metadatos), dilo y lo hago.
