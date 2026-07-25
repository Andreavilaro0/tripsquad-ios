// DTOs del contrato HTTP y su traducción al dominio. El dinero viaja como STRING
// decimal + currencyCode (guía §9, jamás number); se convierte a Int64 de céntimos
// en la frontera con `Dinero` (ADR-0011 §2).

import Foundation
import TripSquadDomain

struct SplitDTO: Codable {
    let kind: String                    // equal | weight | exact
    let among: [String]?
    let weights: [String: Int]?
    let exact: [String: String]?        // céntimos como string decimal
}

struct GastoDTO: Codable {
    let id: String
    let paidBy: String
    let amount: String                  // string decimal, guía §9
    let currency: String                // ISO 4217
    let split: SplitDTO
}

enum DTOError: Error { case divisaNoSoportada(String), repartoInvalido }

// Recibo itemizado (momento mágico #2, ADR-0011): a diferencia de GastoDTO, viaja
// en céntimos (Int64) directamente — no hay número "amount" del usuario que
// convertir en la frontera, el importe se DERIVA del reparto (Task 1/2).
struct ReciboItemDTO: Decodable { let importeMinor: Int64; let sharers: [String] }
struct ReciboDTO: Decodable {
    let gastoId: String
    let pagadoPor: String
    let items: [ReciboItemDTO]
    let impuestosMinor: Int64
    let propinaMinor: Int64
}

extension GastoDTO {
    /// Traduce el DTO a un `Gasto` del dominio, convirtiendo el dinero en la
    /// frontera. Lanza si la divisa o el reparto no son válidos.
    func aDominio() throws -> Gasto {
        let divisa = try Self.divisa(currency)
        let importe = try Dinero.minorUnits(desde: amount, divisa: divisa)
        let reparto: Reparto
        switch split.kind {
        case "equal":
            reparto = .igual(entre: (split.among ?? []).map(MiembroId.init))
        case "weight":
            reparto = .porPeso(Dictionary(uniqueKeysWithValues:
                (split.weights ?? [:]).map { (MiembroId($0.key), $0.value) }))
        case "exact":
            var cuotas: [MiembroId: Int64] = [:]
            for (m, s) in (split.exact ?? [:]) {
                cuotas[MiembroId(m)] = try Dinero.minorUnits(desde: s, divisa: divisa)
            }
            reparto = .exacto(cuotas)
        default:
            throw DTOError.repartoInvalido
        }
        return Gasto(id: id, pagadoPor: MiembroId(paidBy), importeMinor: importe, reparto: reparto)
    }

    static func divisa(_ code: String) throws -> Divisa {
        // Solo EUR por ahora (hallazgo P1 de Codex): el adaptador Postgres persiste
        // `currency_original = 'EUR'` y trata el importe como céntimos de referencia
        // EUR. Aceptar JPY aquí guardaría un importe con semántica equivocada. La
        // multi-divisa (JPY incluido) llega con FX, el 2º incremento (ADR-0011 §5).
        switch code {
        case "EUR": return .eur
        default: throw DTOError.divisaNoSoportada(code)
        }
    }
}
