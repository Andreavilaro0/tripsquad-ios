// Tests del doble en memoria de `ReservaRepositorio` (wedge "quién ya
// reservó", Task 1: solo el almacén — la autorización llega en
// `CasosDeUsoReserva`, tarea aparte).

import Testing
import Foundation
import TripSquadDomain
@testable import TripSquadExpenses

@Suite struct RepositorioReservaEnMemoriaTests {
    let a = MiembroId("a"), b = MiembroId("b")
    func repo() -> RepositorioEnMemoria { RepositorioEnMemoria() }

    @Test func upsertYLeeCadaUnoElSuyo() async throws {
        let r = repo()
        let res = Reserva(activityId: "act1", tripId: "t1", kind: .vuelo,
                          mode: .cadaUnoElSuyo(estados: [a: .pendiente, b: .pendiente]))
        try await r.upsert(res, ahora: Date())
        let leido = try await r.reserva(activityId: "act1", en: "t1")
        #expect(leido == res)
    }

    @Test func marcarEstadoDeUnMiembro() async throws {
        let r = repo()
        try await r.upsert(Reserva(activityId: "act1", tripId: "t1", kind: .vuelo,
            mode: .cadaUnoElSuyo(estados: [a: .pendiente, b: .pendiente])), ahora: Date())
        try await r.marcarEstado(activityId: "act1", en: "t1", miembro: a, estado: .reservado)
        let leido = try await r.reserva(activityId: "act1", en: "t1")
        #expect(leido?.mode == .cadaUnoElSuyo(estados: [a: .reservado, b: .pendiente]))
    }

    @Test func tableroDevuelveTodasOrdenadas() async throws {
        let r = repo()
        try await r.upsert(Reserva(activityId: "act2", tripId: "t1", kind: .hotel,
            mode: .unoParaTodos(responsable: a, estado: .pendiente)), ahora: Date())
        try await r.upsert(Reserva(activityId: "act1", tripId: "t1", kind: .vuelo,
            mode: .cadaUnoElSuyo(estados: [a: .pendiente])), ahora: Date())
        let tablero = try await r.tablero("t1")
        #expect(tablero.map(\.activityId) == ["act1", "act2"])
    }
}
