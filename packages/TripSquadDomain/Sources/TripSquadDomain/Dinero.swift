// Dinero en la frontera.
//
// El motor opera SIEMPRE con `Int64` de céntimos. Este archivo es la única puerta
// donde se convierte desde/hacia el string decimal del contrato (ADR-0011 §2).
// Trampa documentada: `Decimal(0.1)` desde literal `Double` reintroduce el error
// binario, por eso se usa siempre `Decimal(string:)`. `Double` no aparece aquí.

import Foundation

/// Una divisa ISO 4217 con su número de decimales (unidades menores):
/// EUR = 2 (`10,99 € = 1099`), JPY = 0 (zero-decimal: `1000 ¥ = 1000`).
public struct Divisa: Hashable, Sendable {
    public let codigo: String
    public let exponente: Int
    public init(codigo: String, exponente: Int) {
        self.codigo = codigo
        self.exponente = exponente
    }
    public static let eur = Divisa(codigo: "EUR", exponente: 2)
    public static let jpy = Divisa(codigo: "JPY", exponente: 0)
}

public enum DineroError: Error, Equatable {
    /// El string no es un decimal válido, o tiene más decimales de los que la
    /// divisa admite (p. ej. "10.999" en EUR, "10,99", "10.99abc").
    case formatoInvalido
    /// El importe es válido pero no cabe en `Int64` de céntimos.
    case fueraDeRango
}

public enum Dinero {
    /// `"10.99"` (EUR) → `1099`. `"1000"` (JPY) → `1000`. Rechaza formatos con más
    /// decimales de los permitidos por la divisa: no redondea a ciegas.
    public static func minorUnits(desde decimal: String, divisa: Divisa) throws -> Int64 {
        // `Decimal(string:)` de Foundation hace parseo PARCIAL: "10,99" devuelve 10,
        // "10.99abc" devuelve 10.99 (hallazgo P1 de la voz externa Codex). Validamos
        // el string ENTERO contra un formato estricto antes de convertir, para no
        // registrar un importe equivocado en silencio.
        guard esFormatoDecimalValido(decimal) else { throw DineroError.formatoInvalido }
        guard let dec = Decimal(string: decimal, locale: posix) else {
            throw DineroError.formatoInvalido
        }
        let escalado = dec * pow(Decimal(10), divisa.exponente)
        var escaladoVar = escalado
        var redondeado = Decimal()
        NSDecimalRound(&redondeado, &escaladoVar, 0, .plain)
        guard redondeado == escalado else { throw DineroError.formatoInvalido }
        // `int64Value` ENVUELVE en silencio si el valor no cabe (hallazgo P2 de
        // Codex): un céntimo por encima de Int64.max se vuelve Int64.min. Se
        // comprueba el rango antes de convertir.
        guard redondeado >= Decimal(Int64.min), redondeado <= Decimal(Int64.max) else {
            throw DineroError.fueraDeRango
        }
        return NSDecimalNumber(decimal: redondeado).int64Value
    }

    /// `-?\d+(\.\d+)?` estricto: signo opcional, dígitos ASCII, punto opcional con
    /// al menos un dígito detrás. Rechaza comas, texto sobrante, "10.", ".5", "".
    static func esFormatoDecimalValido(_ s: String) -> Bool {
        var cuerpo = Substring(s)
        if cuerpo.first == "-" { cuerpo = cuerpo.dropFirst() }
        guard !cuerpo.isEmpty else { return false }
        let partes = cuerpo.split(separator: ".", omittingEmptySubsequences: false)
        func soloDigitos(_ x: Substring) -> Bool { !x.isEmpty && x.allSatisfy { $0.isASCII && $0.isNumber } }
        switch partes.count {
        case 1: return soloDigitos(partes[0])
        case 2: return soloDigitos(partes[0]) && soloDigitos(partes[1])
        default: return false
        }
    }

    /// `1099` (EUR) → `"10.99"`. `1000` (JPY) → `"1000"`. Sin `Double`.
    public static func decimalString(_ minor: Int64, divisa: Divisa) -> String {
        let negativo = minor < 0
        let magnitud = minor.magnitude
        if divisa.exponente == 0 {
            return (negativo ? "-" : "") + String(magnitud)
        }
        var factor: UInt64 = 1
        for _ in 0..<divisa.exponente { factor *= 10 }
        let entero = magnitud / factor
        let frac = magnitud % factor
        var fracStr = String(frac)
        while fracStr.count < divisa.exponente { fracStr = "0" + fracStr }
        return (negativo ? "-" : "") + "\(entero).\(fracStr)"
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
}
