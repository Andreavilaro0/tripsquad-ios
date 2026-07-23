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

/// Resultado de CREAR una afirmación de pago (ADR-0017).
public enum ResultadoSettle: Equatable, Sendable {
    case creado(id: String)
    case duplicado(id: String)
    case rechazado(razon: String)
}

/// Resultado de una transición (confirm/reject/cancel).
public enum ResultadoTransicion: Equatable, Sendable {
    case ok
    case noAutorizado    // el actor no puede hacer esta transición
    case noEncontrado
    case estadoInvalido  // no está en `pending`
    case caducado        // pending vencido (expiresAt < ahora)
}

public protocol SettlementRepositorio: Sendable {
    /// Crea si la clave natural (tripId+settlementId+from+to+transferIndex) es nueva;
    /// si ya existe → `duplicado` con el id existente (dedupe ADR-0015 §5).
    func crear(_ settlement: Settlement) async throws -> ResultadoSettle
    /// Transición autorizada de `pending` a un estado terminal. La autorización (quién puede)
    /// la decide el CASO DE USO; el repo solo aplica sobre `pending` no caducado.
    func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement,
                      por actor: MiembroId, ahora: Date, rejectReason: String?) async throws -> ResultadoTransicion
    func confirmados(de tripId: String) async throws -> [Settlement]
    /// Pendientes CON su id de almacenamiento (el dominio `Settlement` no lo lleva;
    /// lo genera el repo al crear — ADR-0017, decisión Task 4). El id hace falta para
    /// que el cliente pueda confirmar/rechazar/cancelar el settlement listado.
    func pendientes(de tripId: String) async throws -> [(String, Settlement)]
    /// Lee un settlement por id (para autorizar la transición en el caso de uso).
    func settlement(id: String, en tripId: String) async throws -> Settlement?
}
