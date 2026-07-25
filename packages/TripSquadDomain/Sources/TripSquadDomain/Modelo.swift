// Modelo del dominio. Tipos puros, sin dependencias externas.
//
// Regla de dinero (ADR-0011 §2): TODO importe es `Int64` de unidades menores
// (céntimos). `Double` está prohibido en este archivo y en todo el motor.

/// Identidad opaca de un miembro del viaje. Es un string generado en cliente
/// (UUID); el dominio nunca lo interpreta, solo lo compara. `Comparable` da el
/// orden estable que necesita el determinismo del motor (ADR-0011 §1).
public struct MiembroId: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public static func < (l: MiembroId, r: MiembroId) -> Bool { l.raw < r.raw }
    public var description: String { raw }
}

/// Cómo se reparte un gasto entre participantes.
public enum Reparto: Sendable, Equatable {
    /// Partes iguales; los céntimos sobrantes los asume el pagador (ADR-0011 §8.1).
    case igual(entre: [MiembroId])
    /// Por peso entero positivo (largest remainder ponderado, ADR-0011 §3).
    case porPeso([MiembroId: Int])
    /// Cuotas exactas en céntimos; deben sumar el importe del gasto.
    case exacto([MiembroId: Int64])
}

/// Un gasto: quién pagó, cuánto (en céntimos de la divisa de referencia) y cómo
/// se reparte. El motor solo ve céntimos de referencia — FX vive en la frontera.
public struct Gasto: Sendable, Equatable, Identifiable {
    public let id: String
    public let pagadoPor: MiembroId
    public let importeMinor: Int64
    public let reparto: Reparto
    public init(id: String, pagadoPor: MiembroId, importeMinor: Int64, reparto: Reparto) {
        self.id = id
        self.pagadoPor = pagadoPor
        self.importeMinor = importeMinor
        self.reparto = reparto
    }
}

/// Una transferencia sugerida por la liquidación: `de` paga `importeMinor` a `a`.
public struct Transferencia: Sendable, Equatable {
    public let de: MiembroId
    public let a: MiembroId
    public let importeMinor: Int64
    public init(de: MiembroId, a: MiembroId, importeMinor: Int64) {
        self.de = de
        self.a = a
        self.importeMinor = importeMinor
    }
}

/// Errores de dominio. El motor es total: ante entrada inválida devuelve un error
/// tipado, nunca revienta (ADR: "handle more edge cases").
public enum DomainError: Error, Equatable {
    case importeNegativo
    case cuotasNoCuadran
    case sinParticipantes
    case miembroDuplicado
    case pesoInvalido
    /// La acumulación de saldos (o la suma de cuotas exactas) se sale del rango de
    /// `Int64`. Antes de existir este caso, esa situación TRAPEABA: `+=`/`-=` de Swift
    /// matan el proceso con SIGTRAP en overflow, y `Dinero.minorUnits` acepta importes
    /// hasta `Int64.max`, así que un par de gastos gigantes envenenaba el viaje de forma
    /// PERMANENTE — toda sugerencia de settle y toda consulta de Brújula de ese viaje
    /// mataban el servicio, que sirve a todos los viajes. Ahora es un error de dominio
    /// normal (422), no una caída (P1 de la revisión integrada).
    case saldoFueraDeRango
}
