// Casos de uso de votaciones (M4, ADR-0019 borrador —
// docs/design/votaciones-scope-y-plan.md). La AUTORIZACIÓN es lo crítico de
// este archivo, igual que en `CasosDeUsoViaje`.
//
// Composición del init: `CasosDeUsoVotacion` recibe TRES puertos porque
// necesita dos fuentes de autorización distintas que ya existen en el módulo
// (no se duplican):
//   - `membresia: Membresia`      -> ¿el actor es miembro del viaje? ¿está
//     cerrado? (igual que `CasosDeUsoSettle`, más barato que cargar el viaje
//     entero solo para mirar `closedAt`/`rol`).
//   - `viajes: ViajeRepositorio`  -> SOLO para `cerrar`, que necesita
//     `rol(actor) == .owner` (la única fuente de verdad del rol "owner ligero"
//     de ADR-0018 vive ahí, no se reimplica en el dominio de votaciones).
//   - `repo: VotacionRepositorio` -> persistencia de polls/votos.
//
// Regla transversal (mismo criterio que ADR-0018): `crear`, `listar`,
// `detalle` y `votar` devuelven el MISMO `.noAutorizado` tanto si el actor no
// es miembro como si el tripId/pollId no existen — nunca se filtra existencia
// a quien no tiene derecho a saberlo.

import Foundation
import TripSquadDomain

public struct CasosDeUsoVotacion: Sendable {
    private let repo: VotacionRepositorio
    private let membresia: Membresia
    private let viajes: ViajeRepositorio

    public init(repo: VotacionRepositorio, membresia: Membresia, viajes: ViajeRepositorio) {
        self.repo = repo
        self.membresia = membresia
        self.viajes = viajes
    }

    /// Cualquier miembro puede crear (plan §1). Exige ≥2 `options` (tras
    /// recortar vacíos no tiene sentido votar). Rechaza si el viaje está
    /// cerrado (misma coherencia que onboarding/settle).
    public func crear(tripId: String, question: String, options: [String], actor: MiembroId, ahora: Date) async throws -> Result<Votacion, ErrorVotacion> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }
        guard options.count >= 2 else { return .failure(.reglaViolada("min_2_options")) }
        let votacion = Votacion(id: UUID().uuidString, tripId: tripId, question: question, options: options, createdBy: actor, closedAt: nil)
        try await repo.crear(votacion)
        return .success(votacion)
    }

    /// SOLO miembros listan (plan §5).
    public func listar(tripId: String, actor: MiembroId) async throws -> Result<[Votacion], ErrorVotacion> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        return .success(try await repo.votacionesDe(tripId))
    }

    /// SOLO miembros ven el detalle (con resultados). Un no-miembro recibe
    /// `.noAutorizado` sin ni siquiera consultar el repo — así da lo mismo si
    /// el pollId/tripId existen o no (sin fuga de existencia, igual que
    /// `CasosDeUsoViaje.detalle`). Un miembro pidiendo un pollId que no existe
    /// en SU tripId recibe `.noEncontrado` (no hay fuga: ya está autorizado a
    /// saber qué polls tiene ese viaje).
    public func detalle(pollId: String, tripId: String, actor: MiembroId) async throws -> Result<ResultadoVotacion, ErrorVotacion> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard let resultado = try await repo.resultado(pollId: pollId, en: tripId) else { return .failure(.noEncontrado) }
        return .success(resultado)
    }

    /// SOLO miembros votan; el viaje no puede estar cerrado. La validación de
    /// que la POLL en sí siga abierta y `choice` sea una opción válida se
    /// delega al repo (`votar` upsert por `(pollId, member)` — cambiar de
    /// opción no duplica, plan §2), igual que `CasosDeUsoSettle.registrarPago`
    /// delega la validación de idempotencia estructural a su repo.
    public func votar(pollId: String, tripId: String, choice: String, actor: MiembroId, ahora: Date) async throws -> Result<ResultadoVotar, ErrorVotacion> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }
        let resultado = try await repo.votar(pollId: pollId, tripId: tripId, member: actor, choice: choice, ahora: ahora)
        return .success(resultado)
    }

    /// SOLO el creador de la poll O el owner del viaje cierran (plan §3). Se
    /// carga la votación primero: si no existe (o pertenece a otro tripId),
    /// `.noAutorizado` — mismo criterio sin fuga que el resto del archivo,
    /// aplicado también aquí aunque el plan no lo pida explícito.
    public func cerrar(pollId: String, tripId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorVotacion> {
        guard let votacion = try await repo.votacion(id: pollId, en: tripId) else { return .failure(.noAutorizado) }
        let rolDelActor = try await viajes.rol(de: actor, en: tripId)
        guard votacion.createdBy == actor || rolDelActor == .owner else { return .failure(.noAutorizado) }
        try await repo.cerrar(pollId: pollId, en: tripId, ahora: ahora)
        return .success(())
    }
}
