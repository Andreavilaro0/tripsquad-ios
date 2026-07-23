// Adaptador en memoria: implementación de referencia de los puertos, thread-safe
// (actor). Sirve para tests, previews y como especificación EJECUTABLE de lo que la
// capa Data (Postgres) debe replicar: idempotencia por clave, dedupe estructural
// por id, y detección de conflictos por ETag (ADR-0012, ADR-0013).

import Foundation
import TripSquadDomain

public actor RepositorioEnMemoria: GastoRepositorio, Membresia {

    private struct Fila { var gasto: Gasto; var etag: String; var borrado: Bool }

    private var datos: [String: [String: Fila]] = [:]        // tripId -> gastoId -> fila
    private var respuestaCongelada: [String: ResultadoEscritura] = [:]  // "actor|key" -> resultado
    private var miembros: [String: Set<MiembroId>] = [:]
    private var cerrados: Set<String> = []
    private var settlements: [String: Settlement] = [:]   // idDeterminista -> settlement
    private var version = 0

    // MARK: - Almacenes de onboarding (ADR-0018)

    /// Fila de membresía de `ViajeRepositorio`: `leftAt == nil` = miembro activo
    /// (salió/lo expulsaron deja `leftAt` puesto, no se borra la fila — igual
    /// filosofía que los tombstones de gastos).
    private struct FilaMiembro { var rol: RolMiembro; var leftAt: Date? }

    private var viajes: [String: Viaje] = [:]                             // tripId -> Viaje
    private var miembrosDeViaje: [String: [MiembroId: FilaMiembro]] = [:] // tripId -> actor -> fila
    private var invitaciones: [String: Invitacion] = [:]                  // code -> Invitacion

    // MARK: - Almacenes de votaciones (M4, ADR-0019 borrador)

    private var votaciones: [String: [String: Votacion]] = [:]  // tripId -> pollId -> Votacion
    private var votos: [String: [MiembroId: String]] = [:]      // pollId -> member -> choice (upsert)

    public init() {}

    // MARK: - Setup para tests

    public func anadirMiembro(_ m: MiembroId, a tripId: String) { miembros[tripId, default: []].insert(m) }
    public func cerrarViaje(_ tripId: String) { cerrados.insert(tripId) }

    // MARK: - Membresia

    public func esMiembro(_ m: MiembroId, de tripId: String) -> Bool {
        miembros[tripId]?.contains(m) ?? false
    }
    public func viajeCerrado(_ tripId: String) -> Bool { cerrados.contains(tripId) }

    // MARK: - GastoRepositorio

    /// Clave de idempotencia scopada por actor (ADR-0012 §5): un usuario no puede
    /// secuestrar la clave de otro.
    private func claveIdem(_ actor: MiembroId, _ key: String) -> String { "\(actor.raw)|\(key)" }

    public func respuestaPrevia(actor: MiembroId, idempotencyKey: String) -> ResultadoEscritura? {
        respuestaCongelada[claveIdem(actor, idempotencyKey)].map(comoReplay)
    }

    public func guardar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, idempotencyKey: String) -> ResultadoEscritura {
        let idem = claveIdem(actor, idempotencyKey)
        if let congelada = respuestaCongelada[idem] { return comoReplay(congelada) }

        // Dedupe estructural por id. Incluye los TOMBSTONES: un create con el id de
        // un gasto ya borrado NO resucita la fila (ADR-0013 §5, hallazgo P1 de
        // Codex) — se rechaza como dead-letter visible.
        if let existente = datos[tripId]?[gasto.id] {
            let r: ResultadoEscritura = existente.borrado
                ? .rechazado(razon: "deleted")
                : .reproducido(etag: existente.etag)
            respuestaCongelada[idem] = r
            return r
        }

        let etag = nuevoEtag()
        datos[tripId, default: [:]][gasto.id] = Fila(gasto: gasto, etag: etag, borrado: false)
        let r = ResultadoEscritura.creado(etag: etag)
        respuestaCongelada[idem] = r
        return r
    }

    public func actualizar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) -> ResultadoEscritura {
        let idem = claveIdem(actor, idempotencyKey)
        if let congelada = respuestaCongelada[idem] { return comoReplay(congelada) }

        guard let fila = datos[tripId]?[gasto.id], !fila.borrado else {
            let r = ResultadoEscritura.rechazado(razon: "not_found")
            respuestaCongelada[idem] = r
            return r
        }
        // El árbitro del conflicto es el ETag (ADR-0013 §2), no un reloj.
        guard fila.etag == etag else {
            return .conflicto(serverEtag: fila.etag)   // no se congela: no es terminal
        }
        // (En un adaptador real, aquí se escribiría una fila en expense_revisions
        // con edited_by = actor — ADR-0015 §15.)
        let nuevo = nuevoEtag()
        datos[tripId]![gasto.id] = Fila(gasto: gasto, etag: nuevo, borrado: false)
        let r = ResultadoEscritura.actualizado(etag: nuevo)
        respuestaCongelada[idem] = r
        return r
    }

    public func eliminar(id: String, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) -> ResultadoEscritura {
        let idem = claveIdem(actor, idempotencyKey)
        if let congelada = respuestaCongelada[idem] { return comoReplay(congelada) }

        guard let fila = datos[tripId]?[id], !fila.borrado else {
            // Ya no existe (o ya está tombstoneado): el reintento de un borrado ya
            // hecho no es error (idempotencia del DELETE, ADR-0013 §2 -> 204).
            let r = ResultadoEscritura.eliminado
            respuestaCongelada[idem] = r
            return r
        }
        guard fila.etag == etag else {
            return .conflicto(serverEtag: fila.etag)   // borrar no es ciego ante ediciones
        }
        // Tombstone estructural: se marca borrado, no se olvida (evita resurrección
        // al sincronizar, ADR-0013 §5).
        datos[tripId]![id]!.borrado = true
        let r = ResultadoEscritura.eliminado
        respuestaCongelada[idem] = r
        return r
    }

    public func gastos(de tripId: String) -> [GastoConEtag] {
        (datos[tripId] ?? [:]).values
            .filter { !$0.borrado }
            .map { GastoConEtag(gasto: $0.gasto, etag: $0.etag) }
            .sorted { $0.gasto.id < $1.gasto.id }   // orden estable
    }

    public func gasto(id: String, en tripId: String) -> GastoConEtag? {
        guard let fila = datos[tripId]?[id], !fila.borrado else { return nil }
        return GastoConEtag(gasto: fila.gasto, etag: fila.etag)
    }

    // MARK: - Utilidad

    private func nuevoEtag() -> String { version += 1; return "v\(version)" }

    /// Un replay devuelve el resultado de la primera ejecución, marcado como
    /// reproducido (el efecto ya ocurrió; no se repite).
    private func comoReplay(_ r: ResultadoEscritura) -> ResultadoEscritura {
        switch r {
        case .creado(let e), .actualizado(let e): return .reproducido(etag: e)
        case .reproducido, .eliminado, .conflicto, .rechazado: return r
        }
    }
}

extension RepositorioEnMemoria: SettlementRepositorio {
    /// Dedupe estructural (ADR-0015 §5): la primera vez registra; los reintentos con
    /// la misma clave son `duplicado` (idempotente, no error).
    public func registrar(_ settlement: Settlement) -> ResultadoSettle {
        let clave = settlement.idDeterminista
        if settlements[clave] != nil { return .duplicado }
        settlements[clave] = settlement
        return .registrado
    }
}

extension RepositorioEnMemoria: ViajeRepositorio {

    public func crearViaje(id: String, name: String, baseCurrency: String, creador: MiembroId, ahora: Date) -> Viaje {
        let viaje = Viaje(id: id, name: name, baseCurrency: baseCurrency, createdBy: creador, closedAt: nil)
        viajes[id] = viaje
        // El creador entra como owner en la misma operación (ADR-0018 §2): un
        // viaje sin owner no es un estado válido.
        miembrosDeViaje[id, default: [:]][creador] = FilaMiembro(rol: .owner, leftAt: nil)
        return viaje
    }

    public func viaje(id: String) -> Viaje? { viajes[id] }

    public func viajesDe(_ actor: MiembroId) -> [Viaje] {
        viajes.values
            .filter { miembrosDeViaje[$0.id]?[actor]?.leftAt == nil && miembrosDeViaje[$0.id]?[actor] != nil }
            .sorted { $0.id < $1.id }   // orden estable
    }

    public func miembros(de tripId: String) -> [(MiembroId, RolMiembro)] {
        (miembrosDeViaje[tripId] ?? [:])
            .filter { $0.value.leftAt == nil }
            .map { ($0.key, $0.value.rol) }
            .sorted { $0.0 < $1.0 }    // orden estable
    }

    /// Única fuente de verdad de autorización de este dominio: `nil` = no es
    /// miembro activo (nunca lo fue, o salió/lo expulsaron).
    public func rol(de actor: MiembroId, en tripId: String) -> RolMiembro? {
        guard let fila = miembrosDeViaje[tripId]?[actor], fila.leftAt == nil else { return nil }
        return fila.rol
    }

    public func crearInvitacion(tripId: String, por: MiembroId, code: String, expiresAt: Date) -> Invitacion {
        let inv = Invitacion(code: code, tripId: tripId, createdBy: por, expiresAt: expiresAt, revokedAt: nil)
        invitaciones[code] = inv
        return inv
    }

    /// Idempotente: revocar dos veces la misma invitación sigue siendo `true`
    /// (queda revocada, que es el estado deseado). `false` solo si el code no
    /// existe o pertenece a otro viaje (no se filtra cuál de las dos cosas es).
    public func revocarInvitacion(code: String, en tripId: String, ahora: Date) -> Bool {
        guard let inv = invitaciones[code], inv.tripId == tripId else { return false }
        invitaciones[code] = Invitacion(code: inv.code, tripId: inv.tripId, createdBy: inv.createdBy,
                                         expiresAt: inv.expiresAt, revokedAt: inv.revokedAt ?? ahora)
        return true
    }

    /// Valida en orden: código existe → no revocado → no caducado → viaje no
    /// cerrado → no es ya miembro → hay hueco (tope). Reactiva a quien ya salió
    /// antes (rejoin tras `salir`/`expulsar`) en vez de duplicar la fila.
    public func unirsePorCodigo(code: String, actor: MiembroId, ahora: Date, tope: Int) -> ResultadoUnirse {
        guard let inv = invitaciones[code] else { return .codigoInvalido }
        guard inv.revokedAt == nil else { return .revocado }
        guard inv.expiresAt > ahora else { return .caducado }
        guard let viaje = viajes[inv.tripId] else { return .codigoInvalido }
        guard viaje.closedAt == nil else { return .viajeCerrado }
        if miembrosDeViaje[inv.tripId]?[actor]?.leftAt == nil, miembrosDeViaje[inv.tripId]?[actor] != nil {
            return .yaMiembro
        }
        let activos = (miembrosDeViaje[inv.tripId] ?? [:]).values.filter { $0.leftAt == nil }.count
        guard activos < tope else { return .lleno }
        miembrosDeViaje[inv.tripId, default: [:]][actor] = FilaMiembro(rol: .member, leftAt: nil)
        return .unido
    }

    public func quitarMiembro(_ memberId: MiembroId, de tripId: String, ahora: Date) {
        guard var fila = miembrosDeViaje[tripId]?[memberId] else { return }
        fila.leftAt = ahora
        miembrosDeViaje[tripId]?[memberId] = fila
    }

    public func cerrar(tripId: String, ahora: Date) {
        guard let v = viajes[tripId] else { return }
        viajes[tripId] = Viaje(id: v.id, name: v.name, baseCurrency: v.baseCurrency, createdBy: v.createdBy, closedAt: ahora)
    }
}

extension RepositorioEnMemoria: VotacionRepositorio {

    public func crear(_ v: Votacion) {
        votaciones[v.tripId, default: [:]][v.id] = v
    }

    public func votacion(id: String, en tripId: String) -> Votacion? {
        votaciones[tripId]?[id]
    }

    public func votacionesDe(_ tripId: String) -> [Votacion] {
        (votaciones[tripId] ?? [:]).values.sorted { $0.id < $1.id }   // orden estable
    }

    /// UPSERT por `(pollId, member)` — dedupe estructural, mismo criterio que
    /// la PK de `poll_votes` (plan §2): cambiar de opción sobrescribe el voto
    /// anterior, no lo duplica.
    public func votar(pollId: String, tripId: String, member: MiembroId, choice: String, ahora: Date) -> ResultadoVotar {
        guard let v = votaciones[tripId]?[pollId] else { return .rechazado(razon: "poll_not_found") }
        guard v.closedAt == nil else { return .rechazado(razon: "poll_closed") }
        guard v.options.contains(choice) else { return .rechazado(razon: "invalid_option") }
        votos[pollId, default: [:]][member] = choice
        return .registrado
    }

    /// `conteo` incluye SIEMPRE todas las `options`, aunque tengan 0 votos.
    public func resultado(pollId: String, en tripId: String) -> ResultadoVotacion? {
        guard let v = votaciones[tripId]?[pollId] else { return nil }
        let votosDeLaPoll = votos[pollId] ?? [:]
        var conteo = Dictionary(uniqueKeysWithValues: v.options.map { ($0, 0) })
        for (_, choice) in votosDeLaPoll { conteo[choice, default: 0] += 1 }
        let votosOrdenados = votosDeLaPoll.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return ResultadoVotacion(votacion: v, conteo: conteo, votos: votosOrdenados)
    }

    public func cerrar(pollId: String, en tripId: String, ahora: Date) {
        guard let v = votaciones[tripId]?[pollId] else { return }
        votaciones[tripId]![pollId] = Votacion(id: v.id, tripId: v.tripId, question: v.question, options: v.options, createdBy: v.createdBy, closedAt: ahora)
    }
}
