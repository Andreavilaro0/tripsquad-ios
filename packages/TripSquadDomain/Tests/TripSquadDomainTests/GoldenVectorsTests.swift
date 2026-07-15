// Verifica que cada golden vector es internamente consistente: los saldos y las
// transferencias esperadas son EXACTAMENTE lo que el motor produce hoy. Si el
// motor cambia de comportamiento, estos tests (y el diff del fichero versionado en
// CI) lo cazan. El port de Kotlin deberá reproducir los mismos números.

import Testing
import Foundation
@testable import TripSquadDomain

@Suite("Golden vectors")
struct GoldenVectorsTests {

    /// La generación es determinista: dos builds con la misma semilla dan bytes
    /// idénticos.
    @Test func generacionDeterminista() throws {
        let a = try GoldenVectorsGen.json(GoldenVectorsGen.build(seed: 42, generados: 50))
        let b = try GoldenVectorsGen.json(GoldenVectorsGen.build(seed: 42, generados: 50))
        #expect(a == b)
    }

    /// Cada caso con gastos: recalcular balances desde los gastos da exactamente los
    /// `expectedBalances` guardados, y aplicar `expectedTransfers` deja todo a cero.
    @Test func cadaCasoEsConsistente() throws {
        let vectors = GoldenVectorsGen.build(generados: 500)
        #expect(vectors.cases.count >= 500)
        for caso in vectors.cases {
            // Saldos: suman cero siempre.
            let sumaSaldos = caso.expectedBalances.values.reduce(0, +)
            #expect(sumaSaldos == 0, "caso \(caso.id): saldos no suman cero")

            // Si hay gastos, recomputar y comparar.
            if !caso.expenses.isEmpty {
                let gastos = try caso.expenses.map(reconstruir)
                let recomputado = try balances(gastos)
                let esperado = caso.expectedBalances.filter { $0.value != 0 }
                let obtenido = mapear(recomputado).filter { $0.value != 0 }
                #expect(esperado == obtenido, "caso \(caso.id): balances no coinciden")
            }

            // Aplicar las transferencias esperadas a los saldos deja todo a cero.
            var bal = caso.expectedBalances
            for t in caso.expectedTransfers {
                bal[t.from, default: 0] += t.amountMinor
                bal[t.to, default: 0] -= t.amountMinor
            }
            #expect(bal.values.allSatisfy { $0 == 0 }, "caso \(caso.id): transferencias no cuadran")
        }
    }

    // MARK: - Reconstrucción de un gasto desde su forma golden

    func reconstruir(_ e: GoldenExpense) throws -> Gasto {
        let reparto: Reparto
        switch e.split.kind {
        case "equal":
            reparto = .igual(entre: (e.split.among ?? []).map(MiembroId.init))
        case "weight":
            reparto = .porPeso(Dictionary(uniqueKeysWithValues:
                (e.split.weights ?? [:]).map { (MiembroId($0.key), $0.value) }))
        default:
            reparto = .exacto(Dictionary(uniqueKeysWithValues:
                (e.split.exact ?? [:]).map { (MiembroId($0.key), $0.value) }))
        }
        return Gasto(id: e.id, pagadoPor: MiembroId(e.paidBy), importeMinor: e.amountMinor, reparto: reparto)
    }

    func mapear(_ saldos: [MiembroId: Int64]) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: saldos.map { ($0.key.raw, $0.value) })
    }
}
