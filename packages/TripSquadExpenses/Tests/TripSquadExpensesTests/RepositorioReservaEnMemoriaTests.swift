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

    /// Task 5: expulsar/salir limpia el estado de reserva EN LA MISMA operación que
    /// `quitarMiembro` (consistente con "expulsar revoca huella" — el mismo método ya
    /// revoca invitaciones). `cadaUnoElSuyo` pierde al miembro de sus estados;
    /// `unoParaTodos` vuelve a quedar sin asignar (`responsable = nil`, `.pendiente`).
    @Test func expulsarLimpiaEstadoDeReserva() async throws {
        let r = repo()
        await r.anadirMiembro(a, a: "t1")
        await r.anadirMiembro(b, a: "t1")
        try await r.upsert(Reserva(activityId: "act1", tripId: "t1", kind: .vuelo,
            mode: .cadaUnoElSuyo(estados: [a: .pendiente, b: .pendiente])), ahora: Date())
        try await r.upsert(Reserva(activityId: "act2", tripId: "t1", kind: .hotel,
            mode: .unoParaTodos(responsable: b, estado: .pendiente)), ahora: Date())

        try await r.quitarMiembro(b, de: "t1", ahora: Date())

        let r1 = try await r.reserva(activityId: "act1", en: "t1")
        #expect(r1?.mode == .cadaUnoElSuyo(estados: [a: .pendiente]))
        let r2 = try await r.reserva(activityId: "act2", en: "t1")
        #expect(r2?.mode == .unoParaTodos(responsable: nil, estado: .pendiente))
    }
}
