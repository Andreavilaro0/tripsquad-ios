// Tests del almacén de `Confirmacion` en `RepositorioEnMemoria` y del doble
// determinista `EstructuradorConfirmacionFake` (dy5 Task 1: solo tipos +
// almacén — la orquestación del caso de uso llega en tareas aparte).

import Testing
import Foundation
import TripSquadDomain
@testable import TripSquadExpenses

@Suite struct ConfirmacionEnMemoriaTests {
    let a = MiembroId("a")

    @Test func guardaYLeeConfirmacion() async throws {
        let r = RepositorioEnMemoria()
        let c = Confirmacion(tipo: .vuelo, fechaISO: "2026-09-12", numeroConfirmacion: "ABC123", proveedor: "TAP")
        try await r.guardarConfirmacion(activityId: "act1", en: "t1", miembro: a, c)
        #expect(try await r.confirmacion(activityId: "act1", en: "t1", miembro: a) == c)
    }

    @Test func fakeExtraeYDetectaIlegible() async throws {
        let f = EstructuradorConfirmacionFake(datos: DatosConfirmacion(tipo: .hotel, fechaISO: nil, numeroConfirmacion: "H1", proveedor: nil))
        #expect(try await f.extraer(textoConfirmacion: "reserva hotel").numeroConfirmacion == "H1")
        #expect(f.ultimoTexto == "reserva hotel")
        await #expect(throws: ErrorEstructurador.ilegible) { _ = try await f.extraer(textoConfirmacion: "__ILEGIBLE__") }
    }

    @Test func fakeCuentaLlamadas() async throws {
        let f = EstructuradorConfirmacionFake(datos: DatosConfirmacion(tipo: .coche, fechaISO: nil, numeroConfirmacion: nil, proveedor: nil))
        #expect(f.llamadas == 0)
        _ = try await f.extraer(textoConfirmacion: "uno")
        _ = try await f.extraer(textoConfirmacion: "dos")
        #expect(f.llamadas == 2)
    }
}
