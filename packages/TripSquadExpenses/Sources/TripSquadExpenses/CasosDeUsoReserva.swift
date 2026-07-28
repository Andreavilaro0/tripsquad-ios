// Caso de uso del wedge "quién ya reservó" (spec
// docs/superpowers/specs/2026-07-25-wedge-reserva-por-persona-design.md). La AUTORIZACIÓN calca el
// gate de `CasosDeUsoItinerario.editar/borrar`: se carga primero la
// actividad (sin fuga de existencia si no está), luego se exige miembro
// ACTUAL, y solo el creador de la actividad o el owner del viaje pueden
// definir/quitar el aspecto reserva.
//
// `marcar` tiene su propio gate porque autoriza sobre la RESERVA (no sobre
// la actividad): en `cadaUnoElSuyo` cada miembro marca su propio estado (o
// el owner marca el de cualquiera); en `unoParaTodos` solo el responsable
// (o el owner) marca el estado único.

import Foundation
import TripSquadDomain

public struct CasosDeUsoReserva: Sendable {
    private let repo: ReservaRepositorio
    private let itinerario: ItinerarioRepositorio
    private let membresia: Membresia
    private let viajes: ViajeRepositorio
    private let estructurador: EstructuradorConfirmacion

    /// Cap de coste (endurecimiento post-dy5): tope de longitud del texto de
    /// confirmación. Por encima de esto se rechaza ANTES de llamar al
    /// estructurador — un texto gigante nunca debe llegar al LLM de pago.
    private static let maxLongitudConfirmacion = 20_000

    public init(repo: ReservaRepositorio, itinerario: ItinerarioRepositorio, membresia: Membresia, viajes: ViajeRepositorio,
                estructurador: EstructuradorConfirmacion) {
        self.repo = repo
        self.itinerario = itinerario
        self.membresia = membresia
        self.viajes = viajes
        self.estructurador = estructurador
    }

    /// Marca una actividad como reservable (crea/edita el aspecto). SOLO el
    /// creador de la actividad o el owner del viaje (mismo gate que
    /// `CasosDeUsoItinerario.editar`). `participantes` solo aplica a
    /// `cadaUnoElSuyo` (debe ser un subconjunto no vacío de los miembros
    /// actuales); `responsable` solo a `unoParaTodos` (si no es `nil`, debe
    /// ser miembro actual).
    public func definir(tripId: String, activityId: String, kind: KindReserva,
                        modo: ModoDefinicion, actor: MiembroId, ahora: Date) async throws -> Result<Reserva, ErrorReserva> {
        guard let act = try await itinerario.item(id: activityId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        let rol = try await viajes.rol(de: actor, en: tripId)
        guard act.createdBy == actor || rol == .owner else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }

        let miembros = Set(try await viajes.miembros(de: tripId).map { $0.0 })
        let mode: ModoReserva
        switch modo {
        case .cadaUnoElSuyo(let participantes):
            guard !participantes.isEmpty else { return .failure(.reglaViolada("sin_participantes")) }
            guard participantes.allSatisfy({ miembros.contains($0) }) else { return .failure(.reglaViolada("participante_no_miembro")) }
            mode = .cadaUnoElSuyo(estados: Dictionary(uniqueKeysWithValues: participantes.map { ($0, .pendiente) }))
        case .unoParaTodos(let responsable):
            if let resp = responsable, !miembros.contains(resp) { return .failure(.reglaViolada("responsable_no_miembro")) }
            mode = .unoParaTodos(responsable: responsable, estado: .pendiente)
        }
        let reserva = Reserva(activityId: activityId, tripId: tripId, kind: kind, mode: mode)
        try await repo.upsert(reserva, ahora: ahora)
        return .success(reserva)
    }

    /// Quita el aspecto reserva. Mismo gate que `definir` (creador de la
    /// actividad u owner del viaje). Idempotente vía `repo.borrar` (borrar
    /// algo que no existe no es error).
    ///
    /// Enmienda ADR-0014 §2 (bead iou, hallazgo Codex ronda 2): la membresía
    /// del `tripId` del path se comprueba SIEMPRE primero, ANTES de cargar la
    /// actividad — un no-miembro no puede usar este endpoint como oráculo
    /// para sondear si `activityId` existe (aquí o en otro viaje). Con la
    /// membresía ya verificada, un `activityId` inexistente EN ESTE viaje
    /// (nunca existió, la actividad ya se borró, o es de OTRO viaje) es un
    /// no-op idempotente — `.success` (no hay aspecto reserva que quitar).
    /// Solo si la actividad SÍ existe en este viaje se evalúa "creador u
    /// owner"; si no lo es, `.noAutorizado` (403) — la respuesta nunca varía
    /// según si `activityId` existe en otro viaje.
    public func quitar(tripId: String, activityId: String, actor: MiembroId, ahora: Date) async throws -> Result<Void, ErrorReserva> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard let act = try await itinerario.item(id: activityId, en: tripId) else { return .success(()) }   // idempotente, sin fuga (bead iou)
        let rol = try await viajes.rol(de: actor, en: tripId)
        guard act.createdBy == actor || rol == .owner else { return .failure(.noAutorizado) }
        // Borrado ATÓMICO scopeado por membresía (bead 48g): quitar el aspecto reserva
        // comprueba la membresía ACTUAL en el mismo statement y devuelve `false` si fue
        // revocada durante la request —cierra del todo la ventana TOCTOU que el re-check de
        // iou ronda 3 solo estrechaba—. Sigue siendo idempotente: quitar un aspecto ausente
        // con la membresía vigente devuelve `true` (éxito), no `false`.
        guard try await repo.borrar(activityId: activityId, en: tripId, por: actor) else { return .failure(.noAutorizado) }
        return .success(())
    }

    /// Marca estado. `cadaUnoElSuyo`: `memberId` no-nil y debe estar incluido
    /// en el aspecto reserva; actor == memberId O owner. `unoParaTodos`:
    /// `memberId == nil`; actor == responsable O owner.
    public func marcar(tripId: String, activityId: String, memberId: MiembroId?, estado: EstadoReserva,
                       actor: MiembroId, ahora: Date) async throws -> Result<Reserva, ErrorReserva> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard let reserva = try await repo.reserva(activityId: activityId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }
        let esOwner = (try await viajes.rol(de: actor, en: tripId)) == .owner

        switch reserva.mode {
        case .cadaUnoElSuyo(let estados):
            guard let m = memberId else { return .failure(.reglaViolada("falta_member_id")) }
            guard estados[m] != nil else { return .failure(.reglaViolada("miembro_no_incluido")) }
            guard actor == m || esOwner else { return .failure(.noAutorizado) }
            try await repo.marcarEstado(activityId: activityId, en: tripId, miembro: m, estado: estado)
        case .unoParaTodos(let responsable, _):
            guard responsable != nil else { return .failure(.reglaViolada("sin_responsable")) }
            guard memberId == nil else { return .failure(.reglaViolada("member_id_sobra")) }
            guard actor == responsable || esOwner else { return .failure(.noAutorizado) }
            try await repo.marcarEstado(activityId: activityId, en: tripId, miembro: nil, estado: estado)
        }
        guard let actualizada = try await repo.reserva(activityId: activityId, en: tripId) else { return .failure(.noAutorizado) }
        return .success(actualizada)
    }

    /// El tablero. Solo miembros del viaje.
    public func tablero(tripId: String, actor: MiembroId) async throws -> Result<[Reserva], ErrorReserva> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        return .success(try await repo.tablero(tripId))
    }

    /// Registra la confirmación de reserva del ACTOR (dy5, spec
    /// docs/superpowers/specs/2026-07-25-dy5-confirmaciones-design.md). Mismo gate que `marcar`
    /// con `memberId` fijado al actor (quien sube la confirmación es quien
    /// marca su propia reserva): actor miembro; reserva existente; viaje
    /// abierto; en `cadaUnoElSuyo` el actor debe estar incluido; en
    /// `unoParaTodos` el actor debe ser el responsable o el owner. Sin fuga
    /// de existencia (no-miembro/no-reserva → `noAutorizado`).
    ///
    /// Idempotente por la CLAVE CANÓNICA de la confirmación (ADR-0029): si ya
    /// hay una guardada, la devuelve SIN volver a llamar al
    /// `EstructuradorConfirmacion` (evita coste/reintento del LLM en reenvíos).
    /// En `cadaUnoElSuyo` la clave es `(activityId, actor)` — cada participante
    /// confirma la suya. En `unoParaTodos` es **por-actividad**: la clave es
    /// `(activityId, responsable)` sin importar quién suba (responsable u owner),
    /// de modo que ambos subiendo el mismo billete = UNA sola llamada al LLM
    /// (resuelve el deferido de ADR-0026 §Consecuencias). Si no hay confirmación,
    /// redacta el texto (RGPD — minimización, ver spec §RGPD), lo manda al
    /// extractor, y guarda+marca `.reservado` ATÓMICAMENTE
    /// (`guardarConfirmacionYMarcarReservado`, endurecimiento a62): un fallo
    /// entre el guardado y el marcado no puede dejar estado inconsistente en el
    /// adaptador Postgres. El fallo del extractor (texto ilegible) es
    /// `reglaViolada("confirmacion_ilegible")`, nunca fuga el error interno del
    /// LLM (mismo criterio "sin fuga").
    ///
    /// Cap de coste (endurecimiento post-dy5): si `textoConfirmacion` supera
    /// `maxLongitudConfirmacion` (20_000 chars) se rechaza con
    /// `reglaViolada("confirmacion_muy_larga")` ANTES de llamar al
    /// estructurador — el LLM de pago nunca ve un texto desmesurado. Chequeo
    /// después de la comprobación de idempotencia (un reenvío ya-registrado
    /// sigue siendo gratis) y antes de `redactar`/`extraer`.
    public func registrarConfirmacion(tripId: String, activityId: String, textoConfirmacion: String,
                                      actor: MiembroId, ahora: Date) async throws -> Result<Confirmacion, ErrorReserva> {
        guard try await membresia.esMiembro(actor, de: tripId) else { return .failure(.noAutorizado) }
        guard let reserva = try await repo.reserva(activityId: activityId, en: tripId) else { return .failure(.noAutorizado) }
        guard try await !membresia.viajeCerrado(tripId) else { return .failure(.viajeCerrado) }
        let esOwner = (try await viajes.rol(de: actor, en: tripId)) == .owner

        // Clave canónica de la confirmación: por-actor en cadaUnoElSuyo;
        // por-actividad (el responsable) en unoParaTodos — ver doc arriba (ADR-0029).
        let miembroConfirmacion: MiembroId
        switch reserva.mode {
        case .cadaUnoElSuyo(let estados):
            guard estados[actor] != nil else { return .failure(.reglaViolada("miembro_no_incluido")) }
            miembroConfirmacion = actor
        case .unoParaTodos(let responsable, _):
            guard let responsable else { return .failure(.reglaViolada("sin_responsable")) }
            guard actor == responsable || esOwner else { return .failure(.noAutorizado) }
            miembroConfirmacion = responsable
        }

        if let existente = try await repo.confirmacion(activityId: activityId, en: tripId, miembro: miembroConfirmacion) {
            return .success(existente)
        }

        guard textoConfirmacion.count <= Self.maxLongitudConfirmacion else {
            return .failure(.reglaViolada("confirmacion_muy_larga"))
        }

        let redactado = redactar(textoConfirmacion)
        let datos: DatosConfirmacion
        do {
            datos = try await estructurador.extraer(textoConfirmacion: redactado)
        } catch {
            return .failure(.reglaViolada("confirmacion_ilegible"))
        }

        let confirmacion = Confirmacion(tipo: datos.tipo, fechaISO: datos.fechaISO,
                                        numeroConfirmacion: datos.numeroConfirmacion, proveedor: datos.proveedor)
        try await repo.guardarConfirmacionYMarcarReservado(
            activityId: activityId, en: tripId, miembro: miembroConfirmacion, confirmacion)
        return .success(confirmacion)
    }

    /// Redacta secuencias de 13-19 dígitos (con espacios/guiones) que
    /// parezcan un número de tarjeta, antes de mandar el texto al LLM
    /// (RGPD — minimización, spec §RGPD).
    private func redactar(_ texto: String) -> String {
        texto.replacingOccurrences(
            of: "\\b(?:\\d[ -]?){13,19}\\b",
            with: "[REDACTED]",
            options: .regularExpression)
    }
}

/// Entrada de `definir`: separa la elección de participantes/responsable de
/// los estados internos (que siempre arrancan `.pendiente`, el caso de uso
/// no deja que el llamador los fije al crear).
public enum ModoDefinicion: Equatable, Sendable {
    case cadaUnoElSuyo(participantes: [MiembroId])
    case unoParaTodos(responsable: MiembroId?)
}
