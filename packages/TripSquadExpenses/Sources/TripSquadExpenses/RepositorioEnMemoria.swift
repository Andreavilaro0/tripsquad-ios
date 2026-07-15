// Adaptador en memoria: implementación de referencia de los puertos, thread-safe
// (actor). Sirve para tests, previews y como especificación EJECUTABLE de lo que la
// capa Data (Postgres) debe replicar: idempotencia por clave, dedupe estructural
// por id, y detección de conflictos por ETag (ADR-0012, ADR-0013).

import TripSquadDomain

public actor RepositorioEnMemoria: GastoRepositorio, Membresia {

    private struct Fila { var gasto: Gasto; var etag: String; var borrado: Bool }

    private var datos: [String: [String: Fila]] = [:]        // tripId -> gastoId -> fila
    private var respuestaCongelada: [String: ResultadoEscritura] = [:]  // idempotencyKey -> resultado
    private var miembros: [String: Set<MiembroId>] = [:]
    private var cerrados: Set<String> = []
    private var version = 0

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

    public func guardar(_ gasto: Gasto, en tripId: String, idempotencyKey: String) -> ResultadoEscritura {
        // Capa 1: idempotencia por clave — el reintento devuelve la respuesta
        // congelada, sin re-ejecutar.
        if let congelada = respuestaCongelada[idempotencyKey] { return comoReplay(congelada) }

        // Capa 2: dedupe estructural por id — aunque la clave fallara, el mismo id
        // no se duplica (ADR-0012 §2, la garantía real).
        if let existente = datos[tripId]?[gasto.id], !existente.borrado {
            let r = ResultadoEscritura.reproducido(etag: existente.etag)
            respuestaCongelada[idempotencyKey] = r
            return r
        }

        let etag = nuevoEtag()
        datos[tripId, default: [:]][gasto.id] = Fila(gasto: gasto, etag: etag, borrado: false)
        let r = ResultadoEscritura.creado(etag: etag)
        respuestaCongelada[idempotencyKey] = r
        return r
    }

    public func actualizar(_ gasto: Gasto, en tripId: String, ifMatch etag: String, idempotencyKey: String) -> ResultadoEscritura {
        if let congelada = respuestaCongelada[idempotencyKey] { return comoReplay(congelada) }

        guard let fila = datos[tripId]?[gasto.id], !fila.borrado else {
            let r = ResultadoEscritura.rechazado(razon: "not_found")
            respuestaCongelada[idempotencyKey] = r
            return r
        }
        // El árbitro del conflicto es el ETag (ADR-0013 §2), no un reloj.
        guard fila.etag == etag else {
            return .conflicto(serverEtag: fila.etag)   // no se congela: no es terminal
        }
        let nuevo = nuevoEtag()
        datos[tripId]![gasto.id] = Fila(gasto: gasto, etag: nuevo, borrado: false)
        let r = ResultadoEscritura.actualizado(etag: nuevo)
        respuestaCongelada[idempotencyKey] = r
        return r
    }

    public func eliminar(id: String, en tripId: String, ifMatch etag: String, idempotencyKey: String) -> ResultadoEscritura {
        if let congelada = respuestaCongelada[idempotencyKey] { return comoReplay(congelada) }

        guard let fila = datos[tripId]?[id], !fila.borrado else {
            // Ya no existe: el reintento de un borrado ya hecho no es error
            // (idempotencia del DELETE, ADR-0013 §2 -> 204).
            let r = ResultadoEscritura.eliminado
            respuestaCongelada[idempotencyKey] = r
            return r
        }
        guard fila.etag == etag else {
            return .conflicto(serverEtag: fila.etag)   // borrar no es ciego ante ediciones
        }
        // Tombstone estructural: se marca borrado, no se olvida (evita resurrección
        // al sincronizar, ADR-0013 §5).
        datos[tripId]![id]!.borrado = true
        let r = ResultadoEscritura.eliminado
        respuestaCongelada[idempotencyKey] = r
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
