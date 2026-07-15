// Casos de uso del módulo Expenses. Orquestan: autorización → validación de
// dominio → persistencia vía puerto. No conocen HTTP ni la BD.

import TripSquadDomain

public struct ComandoCrearGasto: Sendable {
    public let tripId: String
    public let gasto: Gasto
    public let actor: MiembroId
    public let idempotencyKey: String
    public init(tripId: String, gasto: Gasto, actor: MiembroId, idempotencyKey: String) {
        self.tripId = tripId; self.gasto = gasto; self.actor = actor; self.idempotencyKey = idempotencyKey
    }
}

public struct ComandoEditarGasto: Sendable {
    public let tripId: String
    public let gasto: Gasto
    public let actor: MiembroId
    public let ifMatch: String
    public let idempotencyKey: String
    public init(tripId: String, gasto: Gasto, actor: MiembroId, ifMatch: String, idempotencyKey: String) {
        self.tripId = tripId; self.gasto = gasto; self.actor = actor; self.ifMatch = ifMatch; self.idempotencyKey = idempotencyKey
    }
}

public struct ComandoEliminarGasto: Sendable {
    public let tripId: String
    public let gastoId: String
    public let actor: MiembroId
    public let ifMatch: String
    public let idempotencyKey: String
    public init(tripId: String, gastoId: String, actor: MiembroId, ifMatch: String, idempotencyKey: String) {
        self.tripId = tripId; self.gastoId = gastoId; self.actor = actor; self.ifMatch = ifMatch; self.idempotencyKey = idempotencyKey
    }
}

/// Los casos de uso de gastos. **Todos los miembros pueden crear/editar/eliminar
/// cualquier gasto** (ADR-0015 §15: sin roles ni candados); la trazabilidad la da
/// el historial de ediciones, no un permiso. El único gate de autorización es la
/// pertenencia al viaje, y que el viaje no esté cerrado.
public struct CasosDeUsoGastos: Sendable {
    private let repo: GastoRepositorio
    private let membresia: Membresia

    public init(repo: GastoRepositorio, membresia: Membresia) {
        self.repo = repo
        self.membresia = membresia
    }

    public func crear(_ c: ComandoCrearGasto) async throws -> ResultadoEscritura {
        // Replay ANTES de re-autorizar (ADR-0012): un reintento de algo ya cometido
        // devuelve la respuesta original aunque al actor lo hayan expulsado entre
        // intentos — si no, el cliente se queda con una escritura "rechazada" de un
        // gasto que sí se guardó (hallazgo P1 de Codex).
        if let previa = try await repo.respuestaPrevia(actor: c.actor, idempotencyKey: c.idempotencyKey) { return previa }
        if let rechazo = try await autorizar(actor: c.actor, tripId: c.tripId) { return rechazo }
        if let rechazo = validarDominio(c.gasto) { return rechazo }
        return try await repo.guardar(c.gasto, en: c.tripId, por: c.actor, idempotencyKey: c.idempotencyKey)
    }

    public func editar(_ c: ComandoEditarGasto) async throws -> ResultadoEscritura {
        if let previa = try await repo.respuestaPrevia(actor: c.actor, idempotencyKey: c.idempotencyKey) { return previa }
        if let rechazo = try await autorizar(actor: c.actor, tripId: c.tripId) { return rechazo }
        if let rechazo = validarDominio(c.gasto) { return rechazo }
        return try await repo.actualizar(c.gasto, en: c.tripId, por: c.actor, ifMatch: c.ifMatch, idempotencyKey: c.idempotencyKey)
    }

    public func eliminar(_ c: ComandoEliminarGasto) async throws -> ResultadoEscritura {
        if let previa = try await repo.respuestaPrevia(actor: c.actor, idempotencyKey: c.idempotencyKey) { return previa }
        if let rechazo = try await autorizar(actor: c.actor, tripId: c.tripId) { return rechazo }
        return try await repo.eliminar(id: c.gastoId, en: c.tripId, por: c.actor, ifMatch: c.ifMatch, idempotencyKey: c.idempotencyKey)
    }

    // MARK: - Reglas comunes

    /// Rechazo permanente si no es miembro o el viaje está cerrado (ADR-0012 §4:
    /// se responde con dead-letter visible, no con un 4xx que congele la cola).
    private func autorizar(actor: MiembroId, tripId: String) async throws -> ResultadoEscritura? {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .rechazado(razon: "not_member") }
        if try await membresia.viajeCerrado(tripId) { return .rechazado(razon: "trip_closed") }
        return nil
    }

    /// El reparto debe cuadrar (ADR-0011). Un gasto cuyas cuotas no suman el importe
    /// se rechaza como dato inválido, no se persiste corrupto.
    private func validarDominio(_ gasto: Gasto) -> ResultadoEscritura? {
        do { _ = try cuotas(de: gasto); return nil }
        catch { return .rechazado(razon: "invalid_expense") }
    }
}
