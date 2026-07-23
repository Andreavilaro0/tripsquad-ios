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

    /// El ETag de `If-Match` (updates/deletes de recurso editable, ADR-0013).
    func ifMatch() -> String? {
        headers[.ifMatch]
    }

    /// El valor crudo de `Authorization`, tal cual llega. Lo interpreta el verificador.
    func autorizacion() -> String? {
        headers[.authorization]
    }
}
