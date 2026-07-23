// Puertos (interfaces) del módulo Expenses. La capa Data (Postgres) los implementa;
// los casos de uso solo hablan con estos protocolos (Clean Architecture, ADR-0009:
// las dependencias apuntan hacia dentro).
//
// El puerto ABSTRAE las decisiones que aún no están cerradas a nivel de
// infraestructura: la mecánica de idempotencia (ADR-0012), la detección de
// conflictos por ETag (ADR-0013) y los tombstones. El caso de uso no las conoce:
// solo ve el resultado tipado `ResultadoEscritura`.

import Foundation
import TripSquadDomain

/// Resultado de una escritura mutante. Modela lo que la capa de contrato traduce a
/// códigos HTTP (§0 de la guía de contrato): distingue creado / reproducido
/// (replay idempotente) / conflicto (ETag no coincide) / rechazado.
public enum ResultadoEscritura: Equatable, Sendable {
    case creado(etag: String)
    case actualizado(etag: String)
    case eliminado
    /// Reintento de algo ya ejecutado: el efecto NO se repite (idempotencia).
    case reproducido(etag: String?)
    /// El `If-Match` no coincidió: otro editó el recurso mientras tanto.
    case conflicto(serverEtag: String)
    /// Rechazo permanente (viaje cerrado, expulsado, validación): la razón se
    /// sincroniza de vuelta al cliente (dead-letter visible, ADR-0012 §4).
    case rechazado(razon: String)
}

/// Un gasto tal como está persistido, con su ETag para control de concurrencia.
public struct GastoConEtag: Equatable, Sendable {
    public let gasto: Gasto
    public let etag: String
    public init(gasto: Gasto, etag: String) {
        self.gasto = gasto
        self.etag = etag
    }
}

/// Puerto de persistencia de gastos. Todas las escrituras llevan `idempotencyKey`
/// (derivada de forma determinista en el cliente, ADR-0012 §6) para que el
/// reintento no duplique, y el `actor` que las hace (para el historial de
/// ediciones `edited_by`, ADR-0015 §15). Las actualizaciones/borrados llevan
/// `ifMatch` (ADR-0013).
///
/// La idempotencia se scopa por **(actor, idempotencyKey)** — igual que el
/// `UNIQUE (user_id, idempotency_key)` del servidor — para que un usuario no pueda
/// secuestrar la clave de otro (ADR-0012 §5, hallazgo de Codex).
public protocol GastoRepositorio: Sendable {
    /// Replay: si esta `(actor, idempotencyKey)` ya se ejecutó, devuelve su
    /// respuesta congelada. Se consulta ANTES de re-autorizar (ADR-0012): un
    /// reintento de algo ya cometido no se rechaza aunque al actor lo hayan
    /// expulsado entre intentos (hallazgo P1 de Codex).
    func respuestaPrevia(actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura?
    func guardar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura
    func gastos(de tripId: String) async throws -> [GastoConEtag]
    func gasto(id: String, en tripId: String) async throws -> GastoConEtag?
    func actualizar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura
    func eliminar(id: String, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura
}

/// Puerto de autorización: ¿este miembro pertenece al viaje? Una sola fuente de
/// verdad (ADR-0013 §4: `trip_members`), la misma que alimentará las RLS.
public protocol Membresia: Sendable {
    func esMiembro(_ miembro: MiembroId, de tripId: String) async throws -> Bool
    func viajeCerrado(_ tripId: String) async throws -> Bool
}

/// Resultado de registrar un pago (ADR-0016). `duplicado` = mismo settlementId ya
/// registrado (idempotencia estructural, ADR-0015 §5), NO es un error.
public enum ResultadoSettle: Equatable, Sendable {
    case registrado
    case duplicado
    case rechazado(razon: String)
}

/// Puerto de persistencia de pagos. La idempotencia es por la clave estructural del
/// Settlement (settlementId + from||to||transferIndex), no por (actor, key).
public protocol SettlementRepositorio: Sendable {
    func registrar(_ settlement: Settlement) async throws -> ResultadoSettle
}

/// Puerto de persistencia de viajes/miembros/invitaciones (ADR-0018). Firma
/// copiada literal del plan (`docs/superpowers/plans/2026-07-24-M2-onboarding.md`).
/// `rol(de:en:) -> RolMiembro?` es la ÚNICA fuente de verdad de autorización de
/// este dominio: `nil` significa "no es miembro" y es indistinguible, desde
/// fuera, de "el viaje no existe" (evita fuga de existencia).
public protocol ViajeRepositorio: Sendable {
    func crearViaje(id: String, name: String, baseCurrency: String, creador: MiembroId, ahora: Date) async throws -> Viaje
    func viaje(id: String) async throws -> Viaje?
    func viajesDe(_ actor: MiembroId) async throws -> [Viaje]
    func miembros(de tripId: String) async throws -> [(MiembroId, RolMiembro)]
    func rol(de actor: MiembroId, en tripId: String) async throws -> RolMiembro?   // nil = no miembro
    func crearInvitacion(tripId: String, por: MiembroId, code: String, expiresAt: Date) async throws -> Invitacion
    func revocarInvitacion(code: String, en tripId: String, ahora: Date) async throws -> Bool
    func unirsePorCodigo(code: String, actor: MiembroId, ahora: Date, tope: Int) async throws -> ResultadoUnirse
    func quitarMiembro(_ memberId: MiembroId, de tripId: String, ahora: Date) async throws
    func cerrar(tripId: String, ahora: Date) async throws
}

/// Puerto de persistencia de votaciones (M4, ADR-0019 borrador). Firma copiada
/// literal de `docs/design/votaciones-scope-y-plan.md`. `votar` es un UPSERT por
/// `(pollId, member)` — cambiar de opción no duplica el voto (dedupe estructural,
/// mismo criterio que `poll_votes` en `db/migrations/0001_expenses.sql`).
public protocol VotacionRepositorio: Sendable {
    func crear(_ v: Votacion) async throws
    func votacion(id: String, en tripId: String) async throws -> Votacion?
    func votacionesDe(_ tripId: String) async throws -> [Votacion]
    func votar(pollId: String, tripId: String, member: MiembroId, choice: String, ahora: Date) async throws -> ResultadoVotar
    func resultado(pollId: String, en tripId: String) async throws -> ResultadoVotacion?
    func cerrar(pollId: String, en tripId: String, ahora: Date) async throws
}

/// Puerto de persistencia de itinerario (M5, ADR-0020 borrador). Firma
/// copiada literal de `docs/design/itinerario-scope-y-plan.md`. `listar`
/// devuelve las actividades ordenadas por `(day, orderIndex)` — el cliente
/// ordena además por `startTime` (plan §4), fuera del alcance del dominio.
public protocol ItinerarioRepositorio: Sendable {
    func crear(_ a: ActividadItinerario, ahora: Date) async throws
    func listar(_ tripId: String) async throws -> [ActividadItinerario]   // ordenado por day, orderIndex
    func item(id: String, en tripId: String) async throws -> ActividadItinerario?
    func actualizar(_ a: ActividadItinerario, ahora: Date) async throws
    func borrar(id: String, en tripId: String) async throws
}
