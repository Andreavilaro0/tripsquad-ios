// Traducción entre el dominio y las columnas SQL. El reparto se guarda como
// (split_kind, split jsonb); las cuotas EXACTAS van además a expense_shares tipada
// (bigint), fuera del jsonb (gate G3, ADR-0015 §4).

import Foundation
import TripSquadDomain
import TripSquadExpenses

enum RepartoCodec {

    struct SplitJSON: Codable {
        var among: [String]?
        var weights: [String: Int]?
    }

    /// (split_kind, split-json, cuotas-exactas). Las cuotas solo se rellenan en
    /// repartos exactos; para equal/weight se derivan y van a null.
    static func aSQL(_ reparto: Reparto) throws -> (kind: String, json: String, shares: [(String, Int64)]?) {
        switch reparto {
        case .igual(let entre):
            let j = try json(SplitJSON(among: entre.map(\.raw), weights: nil))
            return ("equal", j, nil)
        case .porPeso(let pesos):
            let w = Dictionary(uniqueKeysWithValues: pesos.map { ($0.key.raw, $0.value) })
            let j = try json(SplitJSON(among: nil, weights: w))
            return ("weight", j, nil)
        case .exacto(let cuotas):
            let shares = cuotas.map { ($0.key.raw, $0.value) }
            return ("exact", "{}", shares)
        }
    }

    /// Reconstruye el `Reparto` desde las columnas + las filas de expense_shares.
    static func desdeSQL(kind: String, json: String, shares: [(String, Int64)]) throws -> Reparto {
        switch kind {
        case "equal":
            let s = try decode(json)
            return .igual(entre: (s.among ?? []).map(MiembroId.init))
        case "weight":
            let s = try decode(json)
            let w = Dictionary(uniqueKeysWithValues: (s.weights ?? [:]).map { (MiembroId($0.key), $0.value) })
            return .porPeso(w)
        case "exact":
            let x = Dictionary(uniqueKeysWithValues: shares.map { (MiembroId($0.0), $0.1) })
            return .exacto(x)
        default:
            throw AdaptadorError.repartoDesconocido(kind)
        }
    }

    private static func json(_ v: SplitJSON) throws -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(v), as: UTF8.self)
    }
    private static func decode(_ s: String) throws -> SplitJSON {
        try JSONDecoder().decode(SplitJSON.self, from: Data(s.utf8))
    }
}

/// Serialización de la respuesta congelada (idempotency_keys.response_body). Se
/// guarda el resultado de la PRIMERA ejecución para devolverlo tal cual en el replay.
struct RespuestaSerializada: Codable {
    var kind: String          // creado|actualizado|eliminado|reproducido|conflicto|rechazado
    var etag: String?
    var serverEtag: String?
    var razon: String?

    init(_ r: ResultadoEscritura) {
        switch r {
        case .creado(let e):      kind = "creado"; etag = e
        case .actualizado(let e): kind = "actualizado"; etag = e
        case .eliminado:          kind = "eliminado"
        case .reproducido(let e): kind = "reproducido"; etag = e
        case .conflicto(let e):   kind = "conflicto"; serverEtag = e
        case .rechazado(let r):   kind = "rechazado"; razon = r
        }
    }

    /// Al reconstruir para un replay, creado/actualizado se convierten en
    /// reproducido (el efecto ya ocurrió; no se repite).
    var comoReplay: ResultadoEscritura {
        switch kind {
        case "creado", "actualizado", "reproducido": return .reproducido(etag: etag)
        case "eliminado": return .eliminado
        case "conflicto": return .conflicto(serverEtag: serverEtag ?? "")
        default: return .rechazado(razon: razon ?? "unknown")
        }
    }

    var json: String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }
    static func desde(_ s: String) -> RespuestaSerializada? {
        try? JSONDecoder().decode(RespuestaSerializada.self, from: Data(s.utf8))
    }
}

public enum AdaptadorError: Error, Equatable {
    case repartoDesconocido(String)
}
