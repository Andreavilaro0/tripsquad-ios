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
        if let rechazo = try await validarMiembrosDelReparto(c.gasto, tripId: c.tripId) { return rechazo }
        if let rechazo = validarDominio(c.gasto) { return rechazo }
        return try await repo.guardar(c.gasto, en: c.tripId, por: c.actor, idempotencyKey: c.idempotencyKey)
    }

    public func editar(_ c: ComandoEditarGasto) async throws -> ResultadoEscritura {
        if let previa = try await repo.respuestaPrevia(actor: c.actor, idempotencyKey: c.idempotencyKey) { return previa }
        if let rechazo = try await autorizar(actor: c.actor, tripId: c.tripId) { return rechazo }
        if let rechazo = try await validarMiembrosDelReparto(c.gasto, tripId: c.tripId) { return rechazo }
        if let rechazo = validarDominio(c.gasto) { return rechazo }
        return try await repo.actualizar(c.gasto, en: c.tripId, por: c.actor, ifMatch: c.ifMatch, idempotencyKey: c.idempotencyKey)
    }

    public func eliminar(_ c: ComandoEliminarGasto) async throws -> ResultadoEscritura {
        if let previa = try await repo.respuestaPrevia(actor: c.actor, idempotencyKey: c.idempotencyKey) { return previa }
        if let rechazo = try await autorizar(actor: c.actor, tripId: c.tripId) { return rechazo }
        return try await repo.eliminar(id: c.gastoId, en: c.tripId, por: c.actor, ifMatch: c.ifMatch, idempotencyKey: c.idempotencyKey)
    }

    /// Historial append-only de un gasto (bead p4b, ADR-0015 §15). Autorización =
    /// `is_member(trip_id)` — CUALQUIER miembro ve el historial, la misma función
    /// única de ADR-0013 §4 que el resto del módulo (sin candados de permiso,
    /// coherente con "todos editan"). `limit` se clampa a [1, 200] (mismo patrón
    /// que chat/settle), default 50.
    public func revisiones(gastoId: String, tripId: String, actor: MiembroId, limit: Int = 50) async throws -> Result<[RevisionGasto], ErrorGasto> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        // `expenseId` inexistente o de OTRO viaje -> el MISMO `.noAutorizado` (sin
        // fuga de existencia, mismo criterio que `CasosDeUsoItinerario.detalle`).
        guard try await repo.gasto(id: gastoId, en: tripId) != nil else { return .failure(.noAutorizado) }
        let limiteClamp = min(max(limit, 1), 200)
        return .success(try await repo.revisiones(deGasto: gastoId, en: tripId, limit: limiteClamp))
    }

    /// Derecho al olvido RGPD (bead o1v, DECISIÓN de Andrea 2026-07-27, ADR-0027):
    /// borra las revisiones de un autor, GLOBAL (todas sus ediciones en todos los
    /// viajes) — hard-delete, no crypto-shredding. Es un flujo ADMINISTRATIVO de
    /// borrado de cuenta, no una acción de un miembro sobre un viaje concreto: no
    /// lleva gate de `esMiembro` (quien ejerce su propio derecho al olvido puede ya
    /// no ser miembro de ningún viaje, y el flujo de borrado de cuenta no conoce un
    /// `tripId` sobre el que autorizar). Devuelve cuántas filas borró.
    public func olvidarRevisionesDe(_ userId: MiembroId) async throws -> Int {
        try await repo.olvidarRevisionesDe(userId)
    }

    /// Construye el Gasto (.exacto) desde un recibo itemizado y delega en `crear`
    /// (replay + auth + validación + persistencia, ADR-0011 momento mágico #2). El
    /// importe se DERIVA del reparto (suma segura), no de un total externo a reconciliar.
    public func crearDesdeRecibo(tripId: String, gastoId: String, pagadoPor: MiembroId,
                                 items: [ItemRecibo], impuestosMinor: Int64, propinaMinor: Int64,
                                 actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura {
        let reparto: Reparto
        do { reparto = try repartoDesdeRecibo(items: items, impuestosMinor: impuestosMinor, propinaMinor: propinaMinor) }
        catch { return .rechazado(razon: "invalid_receipt") }
        guard case .exacto(let totales) = reparto else { return .rechazado(razon: "invalid_receipt") }
        var importe: Int64 = 0
        for v in totales.values {
            let (s, ov) = importe.addingReportingOverflow(v)
            guard !ov else { return .rechazado(razon: "invalid_receipt") }
            importe = s
        }
        let gasto = Gasto(id: gastoId, pagadoPor: pagadoPor, importeMinor: importe, reparto: reparto)
        return try await crear(ComandoCrearGasto(tripId: tripId, gasto: gasto, actor: actor, idempotencyKey: idempotencyKey))
    }

    // MARK: - Reglas comunes

    /// Rechazo permanente si no es miembro o el viaje está cerrado (ADR-0012 §4:
    /// se responde con dead-letter visible, no con un 4xx que congele la cola).
    private func autorizar(actor: MiembroId, tripId: String) async throws -> ResultadoEscritura? {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .rechazado(razon: "not_member") }
        if try await membresia.viajeCerrado(tripId) { return .rechazado(razon: "trip_closed") }
        return nil
    }

    /// Todos los `MiembroId` que un gasto referencia: quien paga y quienes cargan
    /// con el reparto (los tres tipos de `Reparto`).
    private func miembrosDe(_ gasto: Gasto) -> Set<MiembroId> {
        var miembros: Set<MiembroId> = [gasto.pagadoPor]
        switch gasto.reparto {
        case .igual(let entre): miembros.formUnion(entre)
        case .porPeso(let pesos): miembros.formUnion(pesos.keys)
        case .exacto(let cuotas): miembros.formUnion(cuotas.keys)
        }
        return miembros
    }

    /// `pagadoPor` y todo el reparto deben ser miembros del viaje: si no, un
    /// miembro podría atribuir el pago o el reparto a alguien de fuera, que
    /// terminaría cargando saldo en el settle sin ser parte del viaje (hallazgo
    /// P1 de dos revisores independientes).
    private func validarMiembrosDelReparto(_ gasto: Gasto, tripId: String) async throws -> ResultadoEscritura? {
        for miembro in miembrosDe(gasto) {
            if try await !membresia.esMiembro(miembro, de: tripId) {
                return .rechazado(razon: "member_not_in_trip")
            }
        }
        return nil
    }

    /// El reparto debe cuadrar (ADR-0011). Un gasto cuyas cuotas no suman el importe
    /// se rechaza como dato inválido, no se persiste corrupto.
    private func validarDominio(_ gasto: Gasto) -> ResultadoEscritura? {
        do { _ = try cuotas(de: gasto); return nil }
        catch { return .rechazado(razon: "invalid_expense") }
    }
}
