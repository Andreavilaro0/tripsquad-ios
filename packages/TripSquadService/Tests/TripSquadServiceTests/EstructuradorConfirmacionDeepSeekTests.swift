// Tests del adaptador REAL de DeepSeek (dy5 Task 5). El `ClienteHTTPDeepSeek`
// SIEMPRE es un doble (`ClienteHTTPFalso`, abajo) — este fichero NUNCA toca
// la red ni la API real de DeepSeek. Mismo espíritu que `AuthTests.swift`
// con `FuenteFalsa`.

import Foundation
import Testing
import TripSquadExpenses
@testable import TripSquadServiceCore

/// Doble determinista del POST HTTP: devuelve el `Data` que se le configure,
/// o lanza si se le pide fallar. Registra la última URL/headers/body vistos
/// por si algún test futuro quiere comprobarlos.
actor ClienteHTTPFalso: ClienteHTTPDeepSeek {
    private let respuesta: Data
    private(set) var ultimaURL: String?
    private(set) var ultimosHeaders: [String: String]?
    private(set) var ultimoBody: Data?

    init(respuesta: Data) { self.respuesta = respuesta }

    func post(url: String, headers: [String: String], body: Data) async throws -> Data {
        ultimaURL = url
        ultimosHeaders = headers
        ultimoBody = body
        return respuesta
    }
}

@Suite("EstructuradorConfirmacionDeepSeek (adaptador real, GATED)")
struct EstructuradorConfirmacionDeepSeekTests {

    @Test("extraer: JSON válido en choices[0].message.content -> DatosConfirmacion correcto")
    func extraerCaminoFeliz() async throws {
        let json = #"""
        {"choices":[{"message":{"content":"{\"tipo\":\"vuelo\",\"fechaISO\":\"2026-09-12\",\"numeroConfirmacion\":\"ABC123\",\"proveedor\":\"TAP\"}"}}]}
        """#
        let cliente = ClienteHTTPFalso(respuesta: Data(json.utf8))
        let sut = EstructuradorConfirmacionDeepSeek(apiKey: "clave-de-prueba", httpClient: cliente)

        let datos = try await sut.extraer(textoConfirmacion: "confirmación de vuelo TAP...")

        #expect(datos == DatosConfirmacion(
            tipo: .vuelo, fechaISO: "2026-09-12", numeroConfirmacion: "ABC123", proveedor: "TAP"))

        // El texto se manda como DATOS (mensaje user), con Bearer y a chat/completions.
        let url = await cliente.ultimaURL
        let headers = await cliente.ultimosHeaders
        #expect(url == "https://api.deepseek.com/chat/completions")
        #expect(headers?["Authorization"] == "Bearer clave-de-prueba")
    }

    @Test("extraer: tipo desconocido en el content -> mapea a .otro")
    func extraerTipoDesconocidoMapeaAOtro() async throws {
        let json = #"""
        {"choices":[{"message":{"content":"{\"tipo\":\"crucero\",\"fechaISO\":null,\"numeroConfirmacion\":null,\"proveedor\":null}"}}]}
        """#
        let cliente = ClienteHTTPFalso(respuesta: Data(json.utf8))
        let sut = EstructuradorConfirmacionDeepSeek(apiKey: "clave-de-prueba", httpClient: cliente)

        let datos = try await sut.extraer(textoConfirmacion: "algo")

        #expect(datos.tipo == .otro)
    }

    @Test("extraer: content no es JSON válido -> ErrorEstructurador.ilegible")
    func extraerContentNoJSONLanzaIlegible() async throws {
        let json = #"""
        {"choices":[{"message":{"content":"esto no es json"}}]}
        """#
        let cliente = ClienteHTTPFalso(respuesta: Data(json.utf8))
        let sut = EstructuradorConfirmacionDeepSeek(apiKey: "clave-de-prueba", httpClient: cliente)

        await #expect(throws: ErrorEstructurador.ilegible) {
            _ = try await sut.extraer(textoConfirmacion: "algo")
        }
    }

    @Test("extraer: sobre OpenAI sin choices -> ErrorEstructurador.ilegible")
    func extraerSinChoicesLanzaIlegible() async throws {
        let cliente = ClienteHTTPFalso(respuesta: Data(#"{"choices":[]}"#.utf8))
        let sut = EstructuradorConfirmacionDeepSeek(apiKey: "clave-de-prueba", httpClient: cliente)

        await #expect(throws: ErrorEstructurador.ilegible) {
            _ = try await sut.extraer(textoConfirmacion: "algo")
        }
    }
}
