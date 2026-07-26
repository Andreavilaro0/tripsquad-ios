// Confirmaciones de reserva (dy5 "confirmaciones → auto-marca el wedge"):
// tipos + el puerto que abstrae la extracción estructurada (LLM) del texto de
// confirmación, y su doble determinista para tests. Sigue el mismo criterio
// que `Reserva.swift`: tipos puros aquí, la autorización/orquestación vive en
// el caso de uso (tarea aparte), no en este fichero.

import Foundation
import TripSquadDomain

/// Lo que el `EstructuradorConfirmacion` extrae de un texto libre (LLM).
/// Distinto de `Confirmacion` (lo persistido) aunque hoy tengan la misma
/// forma: son conceptos distintos — este es "lo que salió del extractor",
/// aquel es "lo que se guardó" — y pueden divergir en tareas futuras.
public struct DatosConfirmacion: Equatable, Sendable {
    public let tipo: KindReserva          // reusa el enum del wedge
    public let fechaISO: String?          // 'YYYY-MM-DD'
    public let numeroConfirmacion: String?
    public let proveedor: String?

    public init(tipo: KindReserva, fechaISO: String?, numeroConfirmacion: String?, proveedor: String?) {
        self.tipo = tipo
        self.fechaISO = fechaISO
        self.numeroConfirmacion = numeroConfirmacion
        self.proveedor = proveedor
    }
}

/// Una confirmación de reserva, persistida por miembro/actividad.
public struct Confirmacion: Equatable, Sendable {
    public let tipo: KindReserva
    public let fechaISO: String?
    public let numeroConfirmacion: String?
    public let proveedor: String?

    public init(tipo: KindReserva, fechaISO: String?, numeroConfirmacion: String?, proveedor: String?) {
        self.tipo = tipo
        self.fechaISO = fechaISO
        self.numeroConfirmacion = numeroConfirmacion
        self.proveedor = proveedor
    }
}

/// Errores del extractor. `.ilegible`: el texto no se pudo estructurar
/// (formato irreconocible, escaneo ilegible, etc.) — sin fuga de detalle
/// interno del LLM (mismo criterio "sin fuga" que `ErrorReserva`).
public enum ErrorEstructurador: Error, Sendable {
    case ilegible
}

/// Puerto: extrae datos estructurados de un texto de confirmación (LLM).
/// Lanza si no puede.
public protocol EstructuradorConfirmacion: Sendable {
    func extraer(textoConfirmacion: String) async throws -> DatosConfirmacion
}

/// Fake determinista para tests: devuelve unos `datos` fijos, o lanza
/// `ErrorEstructurador.ilegible` si el texto contiene el marcador
/// "__ILEGIBLE__" (camino de error). Registra el ÚLTIMO texto recibido
/// (`ultimoTexto`, para el test de redacción) y cuenta las llamadas
/// (`llamadas`, para el test de idempotencia) — ambos consumidos en Task 2.
public final class EstructuradorConfirmacionFake: EstructuradorConfirmacion, @unchecked Sendable {
    public private(set) var ultimoTexto: String?
    public private(set) var llamadas = 0
    public var datos: DatosConfirmacion

    public init(datos: DatosConfirmacion) {
        self.datos = datos
    }

    public func extraer(textoConfirmacion: String) async throws -> DatosConfirmacion {
        llamadas += 1
        if textoConfirmacion.contains("__ILEGIBLE__") {
            throw ErrorEstructurador.ilegible
        }
        ultimoTexto = textoConfirmacion
        return datos
    }
}
