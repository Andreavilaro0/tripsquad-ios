// Cabeceras del protocolo de escritura. El actor YA NO se lee de aquí: sale del
// JWT verificado (Auth.swift) y llega al handler por el contexto.

import Foundation
import Hummingbird
import HTTPTypes

extension Request {
    /// La `Idempotency-Key` obligatoria en escrituras mutantes (guía §5).
    func idempotencyKey() -> String? {
        headers[HTTPField.Name("idempotency-key")!]
    }

    /// La `Idempotency-First-Sent` que FIRMA EL CLIENTE en la generación local (ADR-0015 §4,
    /// guía §175-180, bead 5ln): marca temporal ISO-8601 de cuándo se generó la operación,
    /// para descartar reintentos fuera de la ventana de deduplicación (60 días).
    func idempotencyFirstSent() -> String? {
        headers[HTTPField.Name("idempotency-first-sent")!]
    }

    /// El ETag de `If-Match` (updates/deletes de recurso editable, ADR-0013).
    func ifMatch() -> String? {
        headers[.ifMatch]
    }

    /// El valor crudo de `Authorization`, tal cual llega. Lo interpreta el verificador.
    func autorizacion() -> String? {
        headers[.authorization]
    }
}
