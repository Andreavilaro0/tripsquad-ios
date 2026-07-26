// Historial de ediciones de gastos, append-only (ADR-0015 §15, bead p4b) + el
// derecho al olvido RGPD selectivo por autor (bead o1v, DECISIÓN de Andrea
// 2026-07-27, ADR-0027 — enmienda a ADR-0015 §15 / ADR-0013): hard-delete por
// `edited_by`, NO crypto-shredding. Mismo patrón que `Chat.swift`: tipos puros,
// la autorización vive en `CasosDeUsoGastos`, no aquí.

import Foundation
import TripSquadDomain

/// Una entrada del historial append-only de un gasto: quién, cuándo (reloj del
/// SERVIDOR, ADR-0013 §2), qué campo, y su valor antes/después.
/// `oldValue`/`newValue` viajan como texto JSON crudo (la columna es `jsonb`,
/// mismo criterio que `split::text` en `RepositorioPostgres.gastos`): el
/// dominio no necesita parsearlos, solo transportarlos hasta la capa de
/// contrato.
public struct RevisionGasto: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let expenseId: String
    public let editedBy: MiembroId
    public let editedAt: Date
    public let field: String
    public let oldValue: String?
    public let newValue: String?
    public init(id: Int64, expenseId: String, editedBy: MiembroId, editedAt: Date, field: String,
                oldValue: String?, newValue: String?) {
        self.id = id
        self.expenseId = expenseId
        self.editedBy = editedBy
        self.editedAt = editedAt
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

/// Errores de autorización de la lectura de historial (`CasosDeUsoGastos.revisiones`).
/// Un solo caso, mismo criterio "sin fuga de existencia" que `ErrorItinerario`/
/// `ErrorChat`: no-miembro y `expenseId` inexistente (o de OTRO viaje) dan la
/// MISMA respuesta — no se distingue cuál de las dos cosas es.
public enum ErrorGasto: Error, Equatable, Sendable {
    case noAutorizado
}
