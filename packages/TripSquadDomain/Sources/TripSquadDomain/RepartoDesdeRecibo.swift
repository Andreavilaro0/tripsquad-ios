// Reparto de un recibo itemizado (momento mágico #2). El OCR/itemización es
// on-device; aquí solo la cuenta, componiendo primitivas ya testeadas (ADR-0011).
import Foundation

public struct ItemRecibo: Equatable, Sendable {
    public let importeMinor: Int64
    public let sharers: [MiembroId]
    public init(importeMinor: Int64, sharers: [MiembroId]) {
        self.importeMinor = importeMinor; self.sharers = sharers
    }
}

/// Reparto de un recibo: cada ítem se divide a partes iguales entre sus sharers
/// (céntimo sobrante al MiembroId menor), e impuestos+propina se prorratean
/// proporcionalmente al subtotal de cada persona (largest-remainder ponderado).
/// Devuelve `.exacto([MiembroId: total])`, cuya suma es Σ ítems + impuestos + propina.
public func repartoDesdeRecibo(items: [ItemRecibo], impuestosMinor: Int64, propinaMinor: Int64) throws -> Reparto {
    guard !items.isEmpty else { throw DomainError.sinParticipantes }
    guard impuestosMinor >= 0, propinaMinor >= 0 else { throw DomainError.importeNegativo }

    // 1) Subtotal por persona = suma de su parte igual en cada ítem (sobrante al id menor).
    var subtotales: [MiembroId: Int64] = [:]
    for item in items {
        guard item.importeMinor >= 0 else { throw DomainError.importeNegativo }
        guard !item.sharers.isEmpty else { throw DomainError.sinParticipantes }
        try exigirSinDuplicados(item.sharers)
        // pagador = sharer menor por id -> el sobrante cae en él (orden por MiembroId).
        let pagador = item.sharers.min()!
        let porItem = repartoIgual(importe: item.importeMinor, entre: item.sharers, pagador: pagador)
        for (m, v) in porItem {
            let (s, ov) = (subtotales[m] ?? 0).addingReportingOverflow(v)
            guard !ov else { throw DomainError.saldoFueraDeRango }
            subtotales[m] = s
        }
    }

    // 2) Impuestos + propina, prorrateados proporcional al subtotal (porPeso).
    let (tax, ov) = impuestosMinor.addingReportingOverflow(propinaMinor)
    guard !ov else { throw DomainError.saldoFueraDeRango }

    var totales = subtotales
    if tax > 0 {
        // pesos = subtotales > 0 (a Int; en 64-bit Int == Int64). Los de subtotal 0
        // no pagan impuesto (peso 0 no es válido en porPeso).
        var pesos: [MiembroId: Int] = [:]
        for (m, sub) in subtotales where sub > 0 { pesos[m] = Int(sub) }
        guard !pesos.isEmpty else { throw DomainError.sinParticipantes }   // recibo con todo a 0 + impuesto
        let porTax = try repartoPorPeso(importe: tax, pesos: pesos)
        for (m, v) in porTax {
            let (s, ov2) = (totales[m] ?? 0).addingReportingOverflow(v)
            guard !ov2 else { throw DomainError.saldoFueraDeRango }
            totales[m] = s
        }
    }
    return .exacto(totales)
}
