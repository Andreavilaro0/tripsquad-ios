// Endpoints HTTP de fotos (M7 Task 3, ADR-0022 borrador —
// docs/design/fotos-plan-stub.md). Mismo patrón que ChatRoutes/ItinerarioRoutes:
// el grupo AUTENTICADO, el actor SIEMPRE sale de `ctx.actor` (JWT verificado),
// nunca del body. El binario NUNCA pasa por este servicio: el presign devuelve
// una URL de subida (stub hoy, adaptador real cuando se decida el proveedor —
// ADR-0022) a la que el CLIENTE sube directamente.
//
// Mapeo de errores (mismo criterio que ChatRoutes/ItinerarioRoutes):
// `ErrorFoto.noAutorizado`→403, `.noEncontrado`→404, `.reglaViolada(code)`→422
// con ese code. `noAutorizado` es DELIBERADAMENTE el mismo 403 tanto si el
// actor no es miembro, como si el tripId/photoId no existen, como si es
// miembro pero no es ni el subidor ni el owner al borrar (CasosDeUsoFoto) — no
// se filtra existencia ni pertenencia.

import Foundation
import Hummingbird
import HTTPTypes
import TripSquadDomain
import TripSquadExpenses

// MARK: - DTOs de entrada (Decodable)

struct PresignFotoDTO: Decodable {
    let contentType: String
    // Decodable-opcional a propósito: un `sizeBytes` ausente NO es un fallo de decode
    // (que Hummingbird traduciría a 400 genérico) sino una validación de contrato que
    // damos como 422 `missing_size_bytes` (bead 8fd) — mismo criterio que los demás 422
    // de validación del repo. Presente pero fuera de rango lo valida el caso de uso
    // (`size_invalido`). Sin tamaño no se puede acotar la subida (content-length-range).
    let sizeBytes: Int64?
    let caption: String?
}

// MARK: - DTOs de salida (Encodable) — SIEMPRE serializados con JSONEncoder.

private struct PresignCreadoDTO: Encodable {
    let photoId: String
    let uploadUrl: String
    let expiresIn: TimeInterval
}

private struct ConfirmadoDTO: Encodable {
    let status: String
}

private struct FotoListaDTO: Encodable {
    let id: String
    let uploadedBy: String
    let caption: String?
    let url: String
    let createdAt: Date
}

private struct FotosListDTO: Encodable {
    let photos: [FotoListaDTO]
}

/// Fechas en ISO-8601 (mismo criterio que ChatRoutes/ViajeRoutes: el default de
/// JSONEncoder las serializa como epoch-double, poco útil para un cliente HTTP).
private let jsonEncoderFoto: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}()

private func respuestaJSON<T: Encodable>(_ status: HTTPResponse.Status, _ valor: T) throws -> Response {
    let data = try jsonEncoderFoto.encode(valor)
    return Response(status: status, headers: [.contentType: "application/json"],
                     body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

private func dtoDe(_ f: FotoConUrl) -> FotoListaDTO {
    FotoListaDTO(
        id: f.foto.id, uploadedBy: f.foto.uploadedBy.raw, caption: f.foto.caption,
        url: f.url, createdAt: f.foto.createdAt)
}

func montarFotos(_ router: some RouterMethods<ContextoAutenticado>, _ deps: Dependencias) {

    // POST /trips/:tripId/photos/presign — cualquier miembro pide presign
    // (plan §Endpoints). Valida content-type/tamaño el dominio (`reglaViolada`).
    router.post("trips/:tripId/photos/presign") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let dto = try await req.decode(as: PresignFotoDTO.self, context: ctx)
        // `sizeBytes` es OBLIGATORIO (bead 8fd): sin él el adaptador real no puede
        // firmar el content-length-range que impone el tope. Ausente → 422, sin tocar
        // el caso de uso ni crear la foto pending.
        guard let sizeBytes = dto.sizeBytes else {
            return errorJSON(HTTPResponse.Status(code: 422), "missing_size_bytes")
        }
        switch try await deps.casosFoto.presignSubida(
            tripId: tripId, contentType: dto.contentType, sizeBytes: sizeBytes,
            caption: dto.caption, actor: ctx.actor, ahora: deps.ahora()
        ) {
        case .success(let presign):
            return try respuestaJSON(
                .created,
                PresignCreadoDTO(photoId: presign.fotoId, uploadUrl: presign.urlSubida, expiresIn: presign.expiraEn))
        case .failure(let error):
            return respuestaErrorFoto(error)
        }
    }

    // POST /trips/:tripId/photos/:photoId/confirm — SOLO miembros (plan
    // §Endpoints). Idempotente: confirmar una foto ya `ready` sigue siendo 200.
    router.post("trips/:tripId/photos/:photoId/confirm") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let photoId = try ctx.parameters.require("photoId")
        switch try await deps.casosFoto.confirmar(fotoId: photoId, tripId: tripId, actor: ctx.actor) {
        case .success:
            return try respuestaJSON(.ok, ConfirmadoDTO(status: "ready"))
        case .failure(let error):
            return respuestaErrorFoto(error)
        }
    }

    // GET /trips/:tripId/photos?limit= — SOLO miembros (plan §Endpoints, "403 sin
    // fuga"). Solo fotos `ready`, cada una con su URL prefirmada de LECTURA — por eso
    // el tope importa aquí más que en ningún otro listado: cada foto devuelta es una
    // llamada al proveedor de storage. `limit` ausente o no parseable cae al default
    // del caso de uso (50); el clamp [1,200] lo hace `CasosDeUsoFoto.listar`, no esta
    // ruta. Mismo criterio que ChatRoutes: un valor de query inválido NO da 4xx.
    router.get("trips/:tripId/photos") { req, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let limit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? 50
        switch try await deps.casosFoto.listar(tripId: tripId, actor: ctx.actor, limit: limit) {
        case .success(let fotos):
            return try respuestaJSON(.ok, FotosListDTO(photos: fotos.map(dtoDe)))
        case .failure(let error):
            return respuestaErrorFoto(error)
        }
    }

    // DELETE /trips/:tripId/photos/:photoId — SOLO el subidor de la foto O el
    // owner del viaje (plan §Endpoints).
    router.delete("trips/:tripId/photos/:photoId") { _, ctx -> Response in
        let tripId = try ctx.parameters.require("tripId")
        let photoId = try ctx.parameters.require("photoId")
        switch try await deps.casosFoto.borrar(fotoId: photoId, tripId: tripId, actor: ctx.actor) {
        case .success:
            return Response(status: .noContent)
        case .failure(let error):
            return respuestaErrorFoto(error)
        }
    }
}

// MARK: - Mapeo ErrorFoto -> HTTP

private func respuestaErrorFoto(_ error: ErrorFoto) -> Response {
    switch error {
    case .noAutorizado:
        return errorJSON(.forbidden, "not_member")
    case .noEncontrado:
        return errorJSON(.notFound, "not_found")
    case .viajeCerrado:
        return errorJSON(.conflict, "trip_closed")
    case .reglaViolada(let code):
        return errorJSON(HTTPResponse.Status(code: 422), code)
    }
}
