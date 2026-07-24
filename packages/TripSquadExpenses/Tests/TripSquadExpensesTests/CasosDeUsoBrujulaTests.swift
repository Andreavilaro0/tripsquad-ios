// Tests de la Brújula IA (M8 Task 1, ADR-0023 borrador). El foco es la
// AUTORIZACIÓN y que el contexto de saldos que se pasa al asistente sea
// correcto — mismo espíritu que `CasosDeUsoChatTests`/`CasosDeUsoFotoTests`.
// El `AsistenteStub` es determinista y NO llama a ninguna API: los tests
// corren offline, sin gasto.

import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Brújula IA: dominio + stub (M8 Task 1, ADR-0023 borrador)")
struct CasosDeUsoBrujulaTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan"), sara = MiembroId("sara")
    let trip = "trip-1"

    func nuevoEntorno() async -> (CasosDeUsoBrujula, RepositorioEnMemoria) {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(ana, a: trip)
        await repo.anadirMiembro(ivan, a: trip)
        let casos = CasosDeUsoBrujula(repo: repo, membresia: repo, asistente: AsistenteStub())
        return (casos, repo)
    }

    // 1. consultar feliz: la respuesta del stub contiene la query y el
    // resumen de saldos (viaje sin gastos: "todo saldado").
    @Test func consultarFelizDevuelveRespuestaConQueryYSaldos() async throws {
        let (casos, _) = await nuevoEntorno()

        guard case .success(let respuesta) = try await casos.consultar(tripId: trip, query: "¿cómo vamos?", actor: ana) else {
            Issue.record("esperaba consultar exitoso"); return
        }
        #expect(respuesta.contains("¿cómo vamos?"))
        #expect(respuesta.contains("todo saldado"))
    }

    // 2. no-miembro no consulta: `.noAutorizado`, sin fuga de existencia.
    @Test func noMiembroNoConsulta() async throws {
        let (casos, _) = await nuevoEntorno()

        guard case .failure(let error) = try await casos.consultar(tripId: trip, query: "¿quién debe?", actor: sara) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .noAutorizado)
    }

    // 3. query vacía (o solo espacios) se rechaza.
    @Test func queryVaciaSeRechaza() async throws {
        let (casos, _) = await nuevoEntorno()

        guard case .failure(let error) = try await casos.consultar(tripId: trip, query: "   ", actor: ana) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("query_vacia"))
    }

    // 4a. query >500 caracteres se rechaza.
    @Test func queryMuyLargaSeRechaza() async throws {
        let (casos, _) = await nuevoEntorno()

        let queryLarga = String(repeating: "a", count: 501)
        guard case .failure(let error) = try await casos.consultar(tripId: trip, query: queryLarga, actor: ana) else {
            Issue.record("esperaba failure"); return
        }
        #expect(error == .reglaViolada("query_muy_larga"))
    }

    // 4b. query de exactamente 500 caracteres SÍ se acepta (límite inclusive).
    @Test func queryDe500CaracteresSeAcepta() async throws {
        let (casos, _) = await nuevoEntorno()

        let queryLimite = String(repeating: "a", count: 500)
        guard case .success = try await casos.consultar(tripId: trip, query: queryLimite, actor: ana) else {
            Issue.record("esperaba consultar exitoso"); return
        }
    }

    // 5. el resumenSaldos refleja bien un caso con deuda: ana paga 2000
    // repartidos a medias entre ana e ivan -> ana le deben 1000, ivan debe 1000.
    @Test func resumenSaldosReflejaDeudaEnElContexto() async throws {
        let (casos, repo) = await nuevoEntorno()
        let gasto = Gasto(id: "g1", pagadoPor: ana, importeMinor: 2000, reparto: .igual(entre: [ana, ivan]))
        _ = await repo.guardar(gasto, en: trip, por: ana, idempotencyKey: "k1")

        guard case .success(let respuesta) = try await casos.consultar(tripId: trip, query: "¿quién debe?", actor: ana) else {
            Issue.record("esperaba consultar exitoso"); return
        }
        #expect(respuesta.contains("ana le deben 1000"))
        #expect(respuesta.contains("ivan debe 1000"))
    }

    // 6. `formatearResumenSaldos` unitario: saldos en 0 no se listan, orden
    // determinista por MiembroId, y el caso sin deudas es "todo saldado".
    @Test func formatearResumenSaldosOmiteCerosYOrdenaDeterministamente() {
        let saldos: [MiembroId: Int64] = [ivan: -1000, ana: 1000, sara: 0]
        #expect(CasosDeUsoBrujula.formatearResumenSaldos(saldos) == "ana le deben 1000; ivan debe 1000")
        #expect(CasosDeUsoBrujula.formatearResumenSaldos([:]) == "todo saldado")
    }
}
