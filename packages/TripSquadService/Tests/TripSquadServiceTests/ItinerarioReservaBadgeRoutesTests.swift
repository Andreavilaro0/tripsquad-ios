// Test del badge de reserva en el GET de itinerario (bead iab, spec del wedge): el GET
// trae un resumen compacto de reserva por actividad, para que la vista de día no tenga que
// pedir aparte `GET /reservations`. En fichero propio para no engordar `ItinerarioRoutesTests`.

import Foundation
import Testing
import Hummingbird
import HTTPTypes
import HummingbirdTesting
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadServiceCore

@Suite("Itinerario: badge de reserva en el GET (bead iab)")
struct ItinerarioReservaBadgeRoutesTests {
    let trip = "trip-1"
    static let clave = ClaveDePrueba(kid: "test")
    func bearer(_ sub: String) async throws -> String { "Bearer \(try await firmar(Self.clave, sub: sub))" }
    let ahora = Date(timeIntervalSince1970: 1_700_000_000)

    func app() async -> (any ApplicationProtocol, RepositorioEnMemoria) {
        let repo = RepositorioEnMemoria()
        await repo.anadirMiembro(MiembroId("ana"), a: trip)
        await repo.anadirMiembro(MiembroId("ivan"), a: trip)
        let deps = Dependencias(
            casos: CasosDeUsoGastos(repo: repo, membresia: repo),
            casosSettle: CasosDeUsoSettle(repo: repo, membresia: repo),
            casosViaje: CasosDeUsoViaje(repo: repo),
            casosVotacion: CasosDeUsoVotacion(repo: repo, membresia: repo, viajes: repo),
            casosItinerario: CasosDeUsoItinerario(repo: repo, membresia: repo, viajes: repo),
            casosReserva: CasosDeUsoReserva(repo: repo, itinerario: repo, membresia: repo, viajes: repo, estructurador: EstructuradorConfirmacionFake(datos: DatosConfirmacion(tipo: .vuelo, fechaISO: nil, numeroConfirmacion: nil, proveedor: nil))),
            casosChat: CasosDeUsoChat(repo: repo, membresia: repo),
            casosFoto: CasosDeUsoFoto(repo: repo, membresia: repo, viajes: repo, storage: FotoStorageStub()),
            casosBrujula: CasosDeUsoBrujula(repo: repo, membresia: repo, settlements: repo, asistente: AsistenteStub()),
            repo: repo, pingBD: { true },
            verificador: VerificadorSupabase(fuente: FuenteFalsa(jwks(Self.clave)), issuer: issDePrueba, audiencia: audDePrueba))
        return (Application(router: construirRouter(deps)), repo)
    }

    @Test func getItinerarioIncluyeBadgeDeReserva() async throws {
        let (app, repo) = await app()
        // Actividad "act1" reservable (cadaUnoElSuyo): ana ya reservó, ivan pendiente.
        _ = try await repo.crear(ActividadItinerario(id: "act1", tripId: trip, title: "Vuelo a Roma",
            day: "2026-08-02", createdBy: MiembroId("ana")), ahora: ahora)
        try await repo.upsert(Reserva(activityId: "act1", tripId: trip, kind: .vuelo,
            mode: .cadaUnoElSuyo(estados: [MiembroId("ana"): .reservado, MiembroId("ivan"): .pendiente])), ahora: ahora)
        // Actividad "act2" SIN aspecto reserva -> badge nil.
        _ = try await repo.crear(ActividadItinerario(id: "act2", tripId: trip, title: "Cena",
            day: "2026-08-02", createdBy: MiembroId("ana")), ahora: ahora)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/trips/\(trip)/itinerary", method: .get,
                headers: [.authorization: try await bearer("ana")]
            ) { res in
                #expect(res.status == .ok)
                let body = String(buffer: res.body)
                // act1: badge con kind vuelo, 1 de 2 reservado, no completo.
                #expect(body.contains("\"kind\":\"vuelo\""))
                #expect(body.contains("\"reserved\":1"))
                #expect(body.contains("\"total\":2"))
                #expect(body.contains("\"complete\":false"))
                // act2 no es reservable -> su objeto NO lleva la clave `reservation` (JSONEncoder
                // omite los opcionales nil). Solo debe haber UN badge en toda la respuesta.
                #expect(body.components(separatedBy: "\"reservation\":").count - 1 == 1)
            }
        }
    }
}
