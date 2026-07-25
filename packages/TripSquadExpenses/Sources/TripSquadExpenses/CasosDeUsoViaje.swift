// Casos de uso de onboarding (ADR-0018): crear viaje, invitar, unirse, ver
// detalle, salir/expulsar, cerrar. La AUTORIZACIÓN es lo crítico de este
// archivo — cada método documenta su gate antes de tocar el repo.
//
// Regla transversal: `detalle` y `invitar` usan `rol(actor) != nil` como único
// criterio de pertenencia; si el viaje no existe, `rol` también devuelve `nil`,
// así que el error es `.noAutorizado` en ambos casos — nunca se filtra si un
// tripId concreto existe a alguien que no es miembro (ADR-0018, riesgo #3).

import Foundation
import TripSquadDomain

public struct CasosDeUsoViaje: Sendable {
    private let repo: ViajeRepositorio
    private static let duracionInvitacion: TimeInterval = 7 * 24 * 60 * 60   // 7 días
    private static let topeMiembros = 50                                     // ADR-0018 §8

    public init(repo: ViajeRepositorio) {
        self.repo = repo
    }

    /// Crea el viaje; el actor entra como `owner` (lo hace el repo en la misma
    /// operación: crear un viaje sin dueño no es un estado válido). No genera
    /// invitación — eso es un paso explícito con `invitar`.
    public func crear(name: String, baseCurrency: String, actor: MiembroId, ahora: Date) async throws -> Viaje {
        let id = UUID().uuidString
        return try await repo.crearViaje(id: id, name: name, baseCurrency: baseCurrency, creador: actor, ahora: ahora)
    }

    /// `limit` se clampa a [1, 200] (mismo patrón que `CasosDeUsoChat.listar`): un
    /// límite fuera de rango NUNCA se rechaza, se ajusta en silencio. El orden estable
    /// (por `id`) lo garantiza el repo — sin él, paginar no significaría nada.
    public func misViajes(actor: MiembroId, limit: Int = 50) async throws -> [Viaje] {
        let limiteClamp = min(max(limit, 1), 200)
        return try await repo.viajesDe(actor, limit: limiteClamp)
    }

    /// SOLO miembros ven el detalle. Un no-miembro recibe `.noAutorizado` tanto
    /// si el viaje existe como si no — no hay manera de distinguirlos desde
    /// fuera (sin fuga de existencia, ADR-0018).
    public func detalle(tripId: String, actor: MiembroId) async throws -> Result<(Viaje, [(MiembroId, RolMiembro)]), ErrorViaje> {
        guard try await repo.rol(de: actor, en: tripId) != nil else { return .failure(.noAutorizado) }
        guard let viaje = try await repo.viaje(id: tripId) else { return .failure(.noAutorizado) }
        let miembros = try await repo.miembros(de: tripId)
        return .success((viaje, miembros))
    }

    /// Cualquier miembro (owner o member) puede invitar (ADR-0018 §2). Rechaza
    /// si el viaje está cerrado. El code es aleatorio de runtime real —
    /// `UUID().uuidString` da ≥122 bits de entropía, suficiente para no ser
    /// adivinable y es la PK de `trip_invites`.
    /// Devuelve la `Invitacion` COMPLETA (con `expiresAt`) — no solo el code — para que la
    /// capa HTTP no tenga que recalcular la caducidad con una constante duplicada (Gemini P3).
    public func invitar(tripId: String, actor: MiembroId, ahora: Date) async throws -> Result<Invitacion, ErrorViaje> {
        guard try await repo.rol(de: actor, en: tripId) != nil else { return .failure(.noAutorizado) }
        guard let viaje = try await repo.viaje(id: tripId) else { return .failure(.noAutorizado) }
        guard viaje.closedAt == nil else { return .failure(.viajeCerrado) }
        let code = UUID().uuidString
        let expiresAt = ahora.addingTimeInterval(Self.duracionInvitacion)
        let invitacion = try await repo.crearInvitacion(tripId: tripId, por: actor, code: code, expiresAt: expiresAt)
        return .success(invitacion)
    }

    /// SOLO el owner revoca (ADR-0018 §4).
    public func revocar(code: String, tripId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorViaje> {
        guard try await repo.rol(de: actor, en: tripId) == .owner else { return .failure(.noAutorizado) }
        let revocada = try await repo.revocarInvitacion(code: code, en: tripId, ahora: ahora)
        return revocada ? .success(()) : .failure(.noEncontrado)
    }

    /// El código ES la autorización para unirse (ADR-0018 §3): no hay gate de
    /// membresía previo aquí, delega toda la validación (caducado/revocado/
    /// cerrado/lleno/ya-miembro) al repo, que es quien puede hacerlo atómico.
    public func unirse(code: String, actor: MiembroId, ahora: Date) async throws -> ResultadoUnirse {
        try await repo.unirsePorCodigo(code: code, actor: actor, ahora: ahora, tope: Self.topeMiembros)
    }

    /// El actor se quita a sí mismo. DECISIÓN DE DISEÑO: idempotente como no-op
    /// — si ya no es miembro (o nunca lo fue), `salir` no es un error, igual
    /// que `eliminar` en gastos (ADR-0013 §2: reintentar un borrado ya hecho no
    /// es error). Un cliente que reintenta `DELETE /trips/:id/members/me` tras
    /// un timeout de red no debe ver un 4xx la segunda vez.
    ///
    /// Nota abierta (no cerrada por este task): el owner puede salir por esta
    /// vía y dejar el viaje sin owner. El plan no lo prohíbe explícitamente;
    /// se deja así y se marca para revisión de Andrea si hace falta un
    /// "transferir ownership" o "el último no puede salir".
    public func salir(tripId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorViaje> {
        guard try await repo.rol(de: actor, en: tripId) != nil else { return .success(()) }
        try await repo.quitarMiembro(actor, de: tripId, ahora: ahora)
        return .success(())
    }

    /// SOLO el owner expulsa (ADR-0018 §2). El owner NUNCA puede ser expulsado
    /// por esta vía — ni siquiera a sí mismo: para quitarse usa `salir`.
    public func expulsar(tripId: String, memberId: MiembroId, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorViaje> {
        guard try await repo.rol(de: actor, en: tripId) == .owner else { return .failure(.noAutorizado) }
        guard let rolObjetivo = try await repo.rol(de: memberId, en: tripId) else { return .failure(.noEncontrado) }
        guard rolObjetivo != .owner else { return .failure(.reglaViolada("no_se_expulsa_al_owner")) }
        try await repo.quitarMiembro(memberId, de: tripId, ahora: ahora)
        return .success(())
    }

    /// SOLO el owner cierra (ADR-0018 §7): closedAt, no borrado.
    public func cerrar(tripId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorViaje> {
        guard try await repo.rol(de: actor, en: tripId) == .owner else { return .failure(.noAutorizado) }
        try await repo.cerrar(tripId: tripId, ahora: ahora)
        return .success(())
    }
}
