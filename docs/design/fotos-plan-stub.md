# M7 — Fotos — Plan construible (metadatos + puerto + STUB de storage)

> Complementa `docs/design/fotos-scope.md`. Construye TODO menos el adaptador real de storage:
> dominio + metadatos Postgres + endpoints + **stub de `FotoStorage`** (URLs prefirmadas falsas
> pero deterministas). El adaptador real (R2/Supabase/S3) es un swap-in cuando Andrea decida el
> proveedor — SIN cambiar dominio/rutas. ADR-0022 (provisional). Stack sobre M6.

## Puerto de storage (la única frontera con el mundo externo)
```swift
public protocol FotoStorage: Sendable {
    /// URL prefirmada de SUBIDA (PUT directo del cliente al storage). El stub devuelve una
    /// URL `stub://` determinista; el adaptador real la firma contra el bucket.
    func urlDeSubida(storageKey: String, contentType: String, expiraEn: TimeInterval) async throws -> String
    /// URL prefirmada de LECTURA (temporal).
    func urlDeLectura(storageKey: String, expiraEn: TimeInterval) async throws -> String
    func borrar(storageKey: String) async throws
}
/// Stub para dev/tests: URLs deterministas, sin red ni credenciales. NO sube nada real.
public struct FotoStorageStub: FotoStorage { /* devuelve "stub://bucket/\(storageKey)?exp=..." */ }
```

## Dominio (TripSquadExpenses)
```swift
public enum EstadoFoto: String, Sendable, Equatable { case pending, ready }
public struct Foto: Equatable, Sendable {
    public let id: String; public let tripId: String; public let uploadedBy: MiembroId
    public let storageKey: String; public let contentType: String; public let sizeBytes: Int64?
    public let caption: String?; public let status: EstadoFoto; public let createdAt: Date
}
public protocol FotoRepositorio: Sendable {
    func crearPendiente(_ f: Foto) async throws
    func marcarLista(id: String, en tripId: String) async throws -> Bool
    func foto(id: String, en tripId: String) async throws -> Foto?
    func listar(_ tripId: String, soloListas: Bool) async throws -> [Foto]
    func borrar(id: String, en tripId: String) async throws
}
```
`CasosDeUsoFoto(repo:, membresia:, viajes:, storage:)`:
- `presignSubida(tripId, contentType, sizeBytes, actor, ahora)` → solo miembro; valida tipo
  (image/jpeg|png|heic) y tamaño (≤20 MB) → `reglaViolada` si no; genera `id` (UUID) y
  `storageKey = "\(tripId)/\(id)"`; crea Foto pending; devuelve `(fotoId, urlSubida)`.
- `confirmar(fotoId, tripId, actor)` → solo miembro; marca ready (idempotente).
- `listar(tripId, actor)` → solo miembro (403 sin fuga); solo fotos `ready`; adjunta `urlDeLectura`.
- `borrar(fotoId, tripId, actor)` → el subidor O el owner; borra metadato + `storage.borrar(key)`.

## Migración 0007 (tabla photos — igual que fotos-scope.md §Esquema)

## Endpoints
- `POST /trips/:tripId/photos/presign` {contentType, sizeBytes, caption?} → 201 {photoId, uploadUrl, expiresIn}
- `POST /trips/:tripId/photos/:photoId/confirm` → 200 {status:"ready"} · 403 · 404
- `GET /trips/:tripId/photos` → 200 {photos:[{id, uploadedBy, caption, url, createdAt}]}
- `DELETE /trips/:tripId/photos/:photoId` → 204 (subidor u owner) · 403 · 404

## Tareas
1. Dominio: modelos + `FotoRepositorio` + `FotoStorage` + `FotoStorageStub` + `CasosDeUsoFoto` con autorización + RepositorioEnMemoria + tests (presign valida tipo/tamaño, no-miembro 403 sin fuga, confirmar idempotente, listar solo ready + con url, borrar subidor/owner, ex-miembro no borra) + migración 0007.
2. Postgres: `RepositorioPostgres: FotoRepositorio` + tests integración.
3. Service: 4 endpoints (wire `casosFoto` con `FotoStorageStub()` en Dependencias) + tests autorización.
4. Seguridad: revisión + arreglos.

## ADR-0022 (provisional)
Fotos por presigned-URL; binarios en object storage (proveedor por decidir — se construye con
STUB, swap-in del adaptador real sin tocar dominio/rutas). Validación tipo/tamaño en presign.
Borrar = subidor u owner. Provisional, revocable.
