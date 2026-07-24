// Stub de `FotoStorage` (M7 Task 1, ADR-0022 borrador —
// docs/design/fotos-plan-stub.md). Para dev/tests: URLs deterministas, SIN
// red ni credenciales — no sube ni lee nada real. El adaptador real (R2,
// Supabase Storage o S3, proveedor por decidir — `docs/design/fotos-scope.md`)
// implementará el mismo protocolo `FotoStorage` sin que dominio ni casos de
// uso cambien (ADR-0022 §swap-in).

import Foundation

/// Genera URLs `stub://<bucket>/<storageKey>?exp=<segundos>` — deterministas
/// a partir SOLO de sus argumentos (ni reloj, ni red, ni estado): la misma
/// llamada produce siempre la misma URL, lo que hace el stub apto para tests
/// reproducibles. `exp` es el `expiraEn` (en segundos, truncado a entero) que
/// el adaptador real usaría para firmar la caducidad real de la URL.
public struct FotoStorageStub: FotoStorage {
    private let bucket: String

    public init(bucket: String = "tripsquad-stub") {
        self.bucket = bucket
    }

    public func urlDeSubida(storageKey: String, contentType: String, expiraEn: TimeInterval) async throws -> String {
        "stub://\(bucket)/\(storageKey)?exp=\(Int(expiraEn))"
    }

    public func urlDeLectura(storageKey: String, expiraEn: TimeInterval) async throws -> String {
        "stub://\(bucket)/\(storageKey)?exp=\(Int(expiraEn))"
    }

    /// No-op: el stub no guarda ni retiene nada real que borrar.
    public func borrar(storageKey: String) async throws {}
}
