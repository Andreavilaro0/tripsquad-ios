import Foundation
import Testing
import TripSquadDomain
@testable import TripSquadExpenses

@Suite("Máquina de estados de :settle (ADR-0017)")
struct CasosDeUsoSettleTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func setup() async -> (RepositorioEnMemoria, CasosDeUsoSettle) {
        let r = RepositorioEnMemoria()
        await r.anadirMiembro(MiembroId("ana"), a: "t1")
        await r.anadirMiembro(MiembroId("ivan"), a: "t1")
        return (r, CasosDeUsoSettle(repo: r, membresia: r))
    }
    func cmd(_ sid: String = "s1", from: String = "ivan", to: String = "ana",
             amount: Int64 = 2000, actor: String = "ivan") -> ComandoCrearPago {
        .init(tripId: "t1", settlementId: sid, from: MiembroId(from), to: MiembroId(to),
              transferIndex: 0, amountMinor: amount, actor: MiembroId(actor))
    }

    @Test func crearNacePendingYDaId() async throws {
        let (_, casos) = await setup()
        let res = try await casos.crearPagos([cmd()], ahora: t0)
        guard case .creado(let id) = res[0] else { Issue.record("esperaba creado"); return }
        #expect(!id.isEmpty)
    }

    @Test func crearReintentoMismaClaveEsDuplicado() async throws {
        let (_, casos) = await setup()
        _ = try await casos.crearPagos([cmd()], ahora: t0)
        let res = try await casos.crearPagos([cmd(amount: 5)], ahora: t0)  // otro importe, misma clave
        guard case .duplicado = res[0] else { Issue.record("esperaba duplicado"); return }
    }

    @Test func crearActorNoEsParteSeRechaza() async throws {
        let (r, casos) = await setup()
        await r.anadirMiembro(MiembroId("sara"), a: "t1")
        let res = try await casos.crearPagos([cmd(actor: "sara")], ahora: t0)  // sara ∉ {ivan,ana}
        #expect(res[0] == .rechazado(razon: "actor_not_party"))
    }

    @Test func crearParteNoMiembroSeRechaza() async throws {
        let (_, casos) = await setup()
        let res = try await casos.crearPagos([cmd(to: "nadie")], ahora: t0)  // 'nadie' no es miembro
        #expect(res[0] == .rechazado(razon: "payee_not_member"))
    }

    @Test func importeNoPositivoSeRechaza() async throws {
        let (_, casos) = await setup()
        #expect(try await casos.crearPagos([cmd(amount: 0)], ahora: t0)[0] == .rechazado(razon: "invalid_amount"))
    }

    @Test func contraparteConfirma() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        // ivan creó; ana (contraparte) confirma
        let r = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0)
        #expect(r == .ok)
    }

    @Test func creadorNoPuedeConfirmar() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        let r = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ivan"), ahora: t0)  // ivan = creador
        #expect(r == .noAutorizado)
    }

    @Test func creadorCancela() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        #expect(try await casos.cancelar(id: id, en: "t1", por: MiembroId("ivan"), ahora: t0) == .ok)
    }

    @Test func confirmarDosVecesEsIdempotenteNoError() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        _ = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0)
        // repetir la MISMA transición terminal → estadoInvalido (ya no es pending) NO es crash
        #expect(try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0) == .estadoInvalido)
    }

    @Test func rechazarConMotivo() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        #expect(try await casos.rechazar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0, motivo: "no recibí eso") == .ok)
    }

    @Test func pendingCaducadoNoSePuedeConfirmar() async throws {
        let (_, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        let futuro = t0.addingTimeInterval(31 * 24 * 3600)   // > 30 días
        #expect(try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: futuro) == .caducado)
    }

    @Test func soloConfirmadosCuentanParaSaldos() async throws {
        let (r, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        #expect(try await r.confirmados(de: "t1").isEmpty)     // pending no cuenta
        _ = try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0)
        #expect(try await r.confirmados(de: "t1").count == 1)  // confirmed sí
    }

    // --- Arreglos de la revisión multi-modelo de M1 ---

    @Test func autopagoSeRechaza() async throws {   // Gemini P3
        let (_, casos) = await setup()
        let res = try await casos.crearPagos([cmd(from: "ivan", to: "ivan", actor: "ivan")], ahora: t0)
        #expect(res[0] == .rechazado(razon: "self_payment"))
    }

    @Test func expulsadoNoPuedeConfirmar() async throws {   // Codex P2 (ADR-0014)
        let (r, casos) = await setup()
        guard case .creado(let id) = try await casos.crearPagos([cmd()], ahora: t0)[0] else { return }
        await r.expulsar(MiembroId("ana"), de: "t1")   // ana (contraparte) es expulsada del viaje
        // Con JWT aún válido pero ya sin membresía, no puede confirmar.
        #expect(try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0) == .noAutorizado)
    }

    @Test func pendienteCaducadoNoSeLista() async throws {   // Codex P3
        let (_, casos) = await setup()
        _ = try await casos.crearPagos([cmd()], ahora: t0)
        let futuro = t0.addingTimeInterval(31 * 24 * 3600)   // > 30 días
        #expect(try await casos.pendientes(tripId: "t1", ahora: t0).count == 1)    // vigente: se lista
        #expect(try await casos.pendientes(tripId: "t1", ahora: futuro).isEmpty)   // caducado: no se lista
    }

    // MARK: - Tope de listado (patrón chat: clamp [1,200] en el caso de uso)

    /// Un `limit` fuera de rango NUNCA se rechaza: se ajusta en silencio. 0 sube a 1,
    /// 999 baja a 200 (y con 3 pendientes, 200 los devuelve todos).
    @Test func pendientesClampaElLimiteEnVezDeRechazarlo() async throws {
        let (_, casos) = await setup()
        _ = try await casos.crearPagos([cmd("s1"), cmd("s2"), cmd("s3")], ahora: t0)

        #expect(try await casos.pendientes(tripId: "t1", ahora: t0, limit: 0).count == 1)     // 0 -> 1
        #expect(try await casos.pendientes(tripId: "t1", ahora: t0, limit: -5).count == 1)    // negativo -> 1
        #expect(try await casos.pendientes(tripId: "t1", ahora: t0, limit: 999).count == 3)   // 999 -> 200 (caben los 3)
        #expect(try await casos.pendientes(tripId: "t1", ahora: t0).count == 3)               // default 50
    }

    /// El orden debe ser TOTAL y repetible: sin él, `limit` devolvería una página
    /// distinta en cada llamada y paginar no significaría nada. En memoria el criterio
    /// es el orden de creación (= `ORDER BY created_at, id` de Postgres).
    @Test func pendientesTieneOrdenEstableYLaPaginaEsPrefijo() async throws {
        let (_, casos) = await setup()
        _ = try await casos.crearPagos([cmd("s1"), cmd("s2"), cmd("s3")], ahora: t0)

        let completa = try await casos.pendientes(tripId: "t1", ahora: t0, limit: 200).map(\.0)
        #expect(completa.count == 3)
        // Repetir la consulta da EXACTAMENTE la misma secuencia.
        #expect(try await casos.pendientes(tripId: "t1", ahora: t0, limit: 200).map(\.0) == completa)
        // Y la página corta es el PREFIJO de la completa, no un subconjunto al azar.
        #expect(try await casos.pendientes(tripId: "t1", ahora: t0, limit: 2).map(\.0) == Array(completa.prefix(2)))
    }

    /// `confirmados` alimenta los saldos, NO es un listado paginable: no lleva tope
    /// (truncarlo corrompería el cálculo). Sí lleva orden estable.
    @Test func confirmadosNoLlevaTopeYVaOrdenado() async throws {
        let (r, casos) = await setup()
        let res = try await casos.crearPagos([cmd("s1"), cmd("s2"), cmd("s3")], ahora: t0)
        for caso in res {
            guard case .creado(let id) = caso else { Issue.record("esperaba creado"); return }
            #expect(try await casos.confirmar(id: id, en: "t1", por: MiembroId("ana"), ahora: t0) == .ok)
        }
        // Los TRES confirmados salen, y el orden se repite igual entre llamadas.
        let confirmados = try await casos.confirmados(tripId: "t1")
        #expect(confirmados.count == 3)
        #expect(confirmados.map(\.settlementId) == ["s1", "s2", "s3"])   // orden de creación
        #expect(try await r.confirmados(de: "t1").map(\.settlementId) == ["s1", "s2", "s3"])
    }

    /// Bot GitHub P2 sobre la paginación: los pending CADUCADOS no deben consumir la
    /// página. Los más viejos (primeros por `created_at`) son los que más probablemente
    /// caducaron; si el filtro de caducidad se aplicara DESPUÉS del `limit`, taparían a
    /// los pending activos más nuevos, que desaparecerían de `GET /settlements` y de los
    /// flags `pending` de la sugerencia. TTL = 30 días (ADR-0017).
    @Test func pendientesCaducadosNoConsumenLaPagina() async throws {
        let (_, casos) = await setup()
        let treintaUnDia = 31.0 * 24 * 3600
        // Tres pendings viejos (creados en t0, caducan en t0+30d).
        _ = try await casos.crearPagos([cmd("viejo1"), cmd("viejo2"), cmd("viejo3")], ahora: t0)
        // Uno nuevo y ACTIVO, creado 31 días después (caduca en t0+61d).
        let despues = t0.addingTimeInterval(treintaUnDia)
        _ = try await casos.crearPagos([cmd("nuevo", from: "ana", to: "ivan", actor: "ana")], ahora: despues)

        // Consulta en t0+31d con limit=2: los tres viejos ya caducaron; solo "nuevo" sigue.
        let pagina = try await casos.pendientes(tripId: "t1", ahora: despues, limit: 2).map(\.0)
        // Con el filtro DESPUÉS del limit, la página sería [] (los 2 viejos la consumían).
        // Con el filtro ANTES, devuelve el pending activo.
        let sids = try await casos.pendientes(tripId: "t1", ahora: despues, limit: 2)
        #expect(!pagina.isEmpty, "el pending activo no debe quedar oculto por los caducados")
        #expect(sids.allSatisfy { $0.1.expiresAt >= despues }, "ningún caducado en la página")
        #expect(sids.contains { $0.1.settlementId == "nuevo" })
    }

    /// Barrido de caducidad (bead 1ea): pasa a `cancelled` SOLO los `pending` vencidos.
    /// No toca los `pending` vigentes ni los ya terminales (`confirmed`). Idempotente.
    @Test func barridoCaducaSoloPendingsVencidos() async throws {
        let (r, casos) = await setup()
        // s1, s2 nacen en t0 (caducan t0+30d). Confirmo s2 → terminal, intocable.
        let res = try await casos.crearPagos([cmd("s1"), cmd("s2")], ahora: t0)
        guard case .creado(let id2) = res[1] else { Issue.record("esperaba creado"); return }
        _ = try await casos.confirmar(id: id2, en: "t1", por: MiembroId("ana"), ahora: t0)
        // s3: pending VIGENTE, creado 31 días después (caduca t0+61d).
        let despues = t0.addingTimeInterval(31 * 24 * 3600)
        _ = try await casos.crearPagos([cmd("s3", from: "ana", to: "ivan", actor: "ana")], ahora: despues)

        // Barrido en t0+31d: solo s1 (pending vencido) caduca.
        #expect(try await casos.caducarPendientes(ahora: despues) == 1)
        // s3 queda como único pending vigente; s2 sigue confirmado.
        #expect(try await casos.pendientes(tripId: "t1", ahora: despues).map(\.1.settlementId) == ["s3"])
        #expect(try await r.confirmados(de: "t1").count == 1)
        // Idempotente: la 2ª pasada no caduca nada (s1 ya quedó materializado cancelled).
        #expect(try await casos.caducarPendientes(ahora: despues) == 0)
    }
}
