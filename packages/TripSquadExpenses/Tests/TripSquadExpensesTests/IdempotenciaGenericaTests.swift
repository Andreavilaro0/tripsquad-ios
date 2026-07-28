// Tests del mecanismo de idempotencia GENÉRICA a nivel de respuesta (bead 379):
// claim-first + replay + scope por (actor, key). Es la base que usarán los 4 POST
// mutantes sin ETag (chat/itinerario/votaciones/viaje) para no ejecutar el efecto
// dos veces en un reintento. Ver puerto `Idempotencia` en Puertos.swift.

import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Idempotencia genérica de respuesta (bead 379)")
struct IdempotenciaGenericaTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan")

    // 1. Primera vez reclama; tras congelar, un reintento REPRODUCE la misma respuesta
    // exacta (code + body) sin volver a "reclamar".
    @Test func reclamaLuegoCongelaLuegoReproduce() async throws {
        let r = IdempotenciaEnMemoria()
        guard case .reclamado = try await r.reclamar(actor: ana, key: "k1") else {
            Issue.record("la primera vez debe reclamar"); return
        }
        let resp = RespuestaCongelada(code: 201, body: Array(#"{"id":1}"#.utf8))
        try await r.congelar(actor: ana, key: "k1", respuesta: resp)

        guard case .replay(let reproducida) = try await r.reclamar(actor: ana, key: "k1") else {
            Issue.record("tras congelar, un reintento debe reproducir"); return
        }
        #expect(reproducida == resp)
    }

    // 2. Dos reclamos de la misma (actor,key) SIN congelar entremedias: el segundo ve
    // la petición EN VUELO (evita doble ejecución concurrente) → el llamante hará 409.
    @Test func segundoReclamoSinCongelarEsEnVuelo() async throws {
        let r = IdempotenciaEnMemoria()
        guard case .reclamado = try await r.reclamar(actor: ana, key: "k1") else {
            Issue.record("primer reclamo"); return
        }
        guard case .enVuelo = try await r.reclamar(actor: ana, key: "k1") else {
            Issue.record("segundo reclamo sin congelar debe ser enVuelo"); return
        }
    }

    // 3. La clave se scopa por actor (ADR-0012 §5): la misma `key` de otro actor es
    // independiente — un usuario no puede secuestrar la clave de otro.
    @Test func laClaveSeScopaPorActor() async throws {
        let r = IdempotenciaEnMemoria()
        _ = try await r.reclamar(actor: ana, key: "compartida")
        try await r.congelar(actor: ana, key: "compartida", respuesta: RespuestaCongelada(code: 201, body: [1]))

        // ivan usa la MISMA cadena de clave: no ve nada de ana, reclama su propio hueco.
        guard case .reclamado = try await r.reclamar(actor: ivan, key: "compartida") else {
            Issue.record("la clave de ivan es independiente de la de ana"); return
        }
    }

    // 4. (bead 5ln) Misma clave + request_hash DISTINTO = payload distinto → `.payloadDistinto`
    // (el llamante hará 422). Mismo hash → replay normal. Vale tanto en vuelo como ya congelada.
    @Test func mismaKeyOtroHashEsPayloadDistinto() async throws {
        let r = IdempotenciaEnMemoria()
        // 1ª reclamación con hash "h1".
        guard case .reclamado = try await r.reclamar(actor: ana, key: "k", requestHash: "h1") else {
            Issue.record("la primera vez debe reclamar"); return
        }
        // En VUELO (sin congelar aún): mismo hash → enVuelo; otro hash → payloadDistinto.
        guard case .enVuelo = try await r.reclamar(actor: ana, key: "k", requestHash: "h1") else {
            Issue.record("mismo hash en vuelo → enVuelo"); return
        }
        guard case .payloadDistinto = try await r.reclamar(actor: ana, key: "k", requestHash: "h2") else {
            Issue.record("otro hash en vuelo → payloadDistinto"); return
        }
        // Ya congelada: mismo hash → replay; otro hash → payloadDistinto.
        let resp = RespuestaCongelada(code: 201, body: Array(#"{"id":1}"#.utf8))
        try await r.congelar(actor: ana, key: "k", respuesta: resp)
        guard case .replay(let reproducida) = try await r.reclamar(actor: ana, key: "k", requestHash: "h1") else {
            Issue.record("mismo hash congelada → replay"); return
        }
        #expect(reproducida == resp)
        guard case .payloadDistinto = try await r.reclamar(actor: ana, key: "k", requestHash: "h2") else {
            Issue.record("otro hash congelada → payloadDistinto (no replay a ciegas)"); return
        }
    }
}
