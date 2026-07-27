// Doble de test compartido para la carrera TOCTOU de los borrados idempotentes
// (hallazgo Codex bead iou, ronda 3): chat, itinerario, foto y reserva comprueban
// la membresía ANTES de cargar el recurso (gate-oráculo de iou) y de nuevo DESPUÉS
// de cargarlo/autorizar, justo antes de mutar. Este doble reproduce de forma
// DETERMINISTA (sin concurrencia real) "el actor es expulsado mientras corría el
// await de carga": la 1ª comprobación de membresía —el gate-oráculo— pasa como
// miembro y, acto seguido, expulsa al actor del almacén real; así la RE-comprobación
// posterior a la carga ya lo ve como ex-miembro y la mutación debe rechazarse con
// `.noAutorizado`. `rol`/ownership se resuelven contra el almacén real por la rama
// "creador/autor" (que no depende de la membresía actual), de modo que el ÚNICO
// gate capaz de rechazar al expulsado es el re-check que arregla la carrera.

import Foundation
import TripSquadDomain
@testable import TripSquadExpenses

final class MembresiaExpulsaTrasPrimerCheck: Membresia, @unchecked Sendable {
    private let real: RepositorioEnMemoria
    private let victima: MiembroId
    private let tripId: String
    private var yaExpulso = false

    init(real: RepositorioEnMemoria, expulsando victima: MiembroId, de tripId: String) {
        self.real = real
        self.victima = victima
        self.tripId = tripId
    }

    func esMiembro(_ m: MiembroId, de trip: String) async throws -> Bool {
        let miembroAhora = try await real.esMiembro(m, de: trip)
        // Expulsión intra-request: SOLO tras la primera comprobación (el gate-oráculo),
        // para que ese gate pase y el fallo lo provoque el re-check posterior a la carga.
        if !yaExpulso, m == victima, trip == tripId {
            yaExpulso = true
            await real.expulsar(victima, de: tripId)
        }
        return miembroAhora
    }

    func viajeCerrado(_ trip: String) async throws -> Bool {
        try await real.viajeCerrado(trip)
    }
}
