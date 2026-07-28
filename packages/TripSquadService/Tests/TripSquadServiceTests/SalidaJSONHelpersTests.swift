// Tests del bead db0: los helpers de salida compartidos (`errorJSON`/`conEtag`)
// construían el JSON interpolando strings — la única superficie de salida que no
// pasaba por JSONEncoder. Con valores server-side no era explotable, pero un `"` o
// un `\` en el valor rompían el JSON. Estos tests fijan que el body ahora se escapa
// correctamente (round-trip íntegro) para cualquier valor, cerrando el hueco antes
// de que un `reglaViolada(code)` futuro lleve texto de usuario.

import Foundation
import Testing
@testable import TripSquadServiceCore

@Suite("Salida JSON: escaping de errorJSON/conEtag (bead db0)")
struct SalidaJSONHelpersTests {

    private struct ErrorDecodificado: Decodable { struct C: Decodable { let code: String }; let error: C }
    private struct EtagDecodificado: Decodable { let etag: String; let result: String }

    // 1. Un código con comillas/backslash/llaves produce JSON VÁLIDO que decodifica
    // exactamente al valor original (la interpolación vieja habría roto el JSON).
    @Test func errorJSONEscapaCaracteresQueRomperianElJSON() throws {
        let peligroso = #"a"b\c{"code":"x"}"#
        let data = cuerpoErrorJSON(peligroso)
        let dto = try JSONDecoder().decode(ErrorDecodificado.self, from: data)
        #expect(dto.error.code == peligroso)
    }

    // 2. Igual para conEtag: etag y result con comillas se escapan y round-trip íntegro.
    @Test func conEtagEscapaComillasEnEtagYResult() throws {
        let data = cuerpoEtagResultadoJSON(etag: #"e"tag\1"#, resultado: #"crea"do"#)
        let dto = try JSONDecoder().decode(EtagDecodificado.self, from: data)
        #expect(dto.etag == #"e"tag\1"#)
        #expect(dto.result == #"crea"do"#)
    }

    // 3. El caso normal (valores server-side) decodifica a los valores esperados. NO se
    // asume orden de claves: JSONEncoder sin `.sortedKeys` no lo garantiza, y los
    // consumidores del body parsean por clave (los tests de gastos leen los headers).
    @Test func formaNormalDecodificaALosValoresEsperados() throws {
        let err = try JSONDecoder().decode(ErrorDecodificado.self, from: cuerpoErrorJSON("member_not_in_trip"))
        #expect(err.error.code == "member_not_in_trip")
        let etag = try JSONDecoder().decode(EtagDecodificado.self, from: cuerpoEtagResultadoJSON(etag: "abc123", resultado: "created"))
        #expect(etag.etag == "abc123")
        #expect(etag.result == "created")
    }
}
