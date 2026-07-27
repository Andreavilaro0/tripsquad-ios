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

    /// Topes de longitud (bead mjp, "campos de texto libre sin límite"): defensa
    /// de coste/abuso, mismo criterio y unidad que `CasosDeUsoChat.enviar`
    /// (`unicodeScalars.count` == `char_length` de Postgres, ver ese docstring
    /// para el razonamiento completo). `name` es un título corto (~200, mismo
    /// orden que `CasosDeUsoItinerario.title`); `baseCurrency` es un código
    /// ISO 4217 de 3 letras — 10 es techo de sobra sin fijar el formato aquí.
    private static let longitudMaximaName = 200
    private static let longitudMaximaBaseCurrency = 10

    public init(repo: ViajeRepositorio) {
        self.repo = repo
    }

    /// Crea el viaje; el actor entra como `owner` (lo hace el repo en la misma
    /// operación: crear un viaje sin dueño no es un estado válido). No genera
    /// invitación — eso es un paso explícito con `invitar`.
    public func crear(name: String, baseCurrency: String, actor: MiembroId, ahora: Date) async throws -> Result<Viaje, ErrorViaje> {
        guard name.unicodeScalars.count <= Self.longitudMaximaName else { return .failure(.reglaViolada("name_muy_largo")) }
        guard baseCurrency.unicodeScalars.count <= Self.longitudMaximaBaseCurrency else { return .failure(.reglaViolada("base_currency_muy_largo")) }
        let id = UUID().uuidString
        let viaje = try await repo.crearViaje(id: id, name: name, baseCurrency: baseCurrency, creador: actor, ahora: ahora)
        return .success(viaje)
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
    /// Enmienda ADR-0018 (decisión de Andrea 2026-07-27, cierra el hueco descrito
    /// en la nota anterior de este docstring): si `actor` es el ÚNICO `owner`
    /// activo, ANTES de quitarlo se transfiere la propiedad al miembro activo más
    /// antiguo por `joined_at` (excluyéndolo a él). Si no hay otro miembro activo,
    /// el viaje queda sin miembros — eso sí es un estado válido (a diferencia de
    /// "con miembros pero sin owner"). Un owner que NO es el último, o un
    /// `member`, salen sin transferencia: solo el ÚLTIMO owner puede dejar el
    /// viaje huérfano de autoridad.
    public func salir(tripId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorViaje> {
        guard let rolActor = try await repo.rol(de: actor, en: tripId) else { return .success(()) }
        if rolActor == .owner {
            let owners = try await repo.miembros(de: tripId).filter { $0.1 == .owner }
            if owners.count == 1, let sucesor = try await repo.miembroActivoMasAntiguo(de: tripId, excluyendo: actor) {
                try await repo.promoverAOwner(sucesor, en: tripId)
            }
        }
        try await repo.quitarMiembro(actor, de: tripId, ahora: ahora)
        return .success(())
    }

    /// SOLO el owner expulsa (ADR-0018 §2). El owner NUNCA puede ser expulsado
    /// por esta vía — ni siquiera a sí mismo: para quitarse usa `salir`.
    ///
    /// Enmienda ADR-0014 §2 (bead iou, hallazgo Codex ronda 2): la
    /// autorización — ser owner ACTIVO del `tripId` del path — se comprueba
    /// SIEMPRE primero, ANTES de mirar al `memberId` objetivo; así un no-owner
    /// nunca puede usar este endpoint como oráculo. Con eso ya verificado, si
    /// `memberId` no es miembro ACTIVO de este viaje (nunca lo fue, ya salió/
    /// fue expulsado, o es miembro de OTRO viaje) es un no-op idempotente —
    /// `.success` en vez de `.noEncontrado`, mismo criterio "sin fuga" y mismo
    /// idempotente-por-reintento que `repo.quitarMiembro` (ya es un no-op
    /// seguro si `memberId` no está activo). La respuesta nunca varía según si
    /// `memberId` es miembro de otro viaje.
    public func expulsar(tripId: String, memberId: MiembroId, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorViaje> {
        guard try await repo.rol(de: actor, en: tripId) == .owner else { return .failure(.noAutorizado) }
        guard let rolObjetivo = try await repo.rol(de: memberId, en: tripId) else { return .success(()) }   // idempotente, sin fuga (bead iou)
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
