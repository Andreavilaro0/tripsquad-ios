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
    /// Historial append-only (ADR-0015 §15, bead p4b): `expenseId -> revisiones`,
    /// en orden de inserción (= orden cronológico, `nuevaRevisionId()` es
    /// monotónico creciente). El doble TAMBIÉN registra revisiones al editar
    /// (antes solo lo hacía un comentario) — si no, `revisiones`/
    /// `olvidarRevisionesDe` no serían testeables sin Postgres (mismo criterio "el
    /// doble no debe mentir" que ya vale para membresía/viaje cerrado, lección de
    /// la revisión integrada).
    private var revisionesPorGasto: [String: [RevisionGasto]] = [:]
    private var proximaRevisionId: Int64 = 1
    // NOTA: no hay almacén propio de membresía ni de "cerrados". `esMiembro` y
    // `viajeCerrado` derivan de `miembrosDeViaje` y `viajes` (los de onboarding), que
    // son la única fuente de verdad — ver el bloque de helpers de test más abajo.
    private var settlements: [String: Settlement] = [:]   // id generado -> settlement
    /// Ids en ORDEN DE CREACIÓN. `Settlement` (dominio) no lleva `createdAt`, así que
    /// este array es lo único que puede reproducir aquí el `ORDER BY created_at, id`
    /// de Postgres: el orden de inserción ES el orden de `created_at`.
    private var ordenSettlements: [String] = []
    private var contadorSettlement = 0
    private var version = 0

    // MARK: - Almacenes de onboarding (ADR-0018)

    /// Fila de membresía de `ViajeRepositorio`: `leftAt == nil` = miembro activo
    /// (salió/lo expulsaron deja `leftAt` puesto, no se borra la fila — igual
    /// filosofía que los tombstones de gastos). `joinedAt` replica la columna
    /// `trip_members.joined_at` (0001) — necesaria para elegir sucesor de
    /// ownership por antigüedad (enmienda ADR-0018).
    private struct FilaMiembro { var rol: RolMiembro; var leftAt: Date?; var joinedAt: Date }

    private var viajes: [String: Viaje] = [:]                             // tripId -> Viaje
    private var miembrosDeViaje: [String: [MiembroId: FilaMiembro]] = [:] // tripId -> actor -> fila
    private var invitaciones: [String: Invitacion] = [:]                  // code -> Invitacion

    // MARK: - Almacenes de votaciones (M4, ADR-0019 borrador)

    private var votaciones: [String: [String: Votacion]] = [:]  // tripId -> pollId -> Votacion
    private var votos: [String: [MiembroId: String]] = [:]      // pollId -> member -> choice (upsert)

    // MARK: - Almacén de itinerario (M5, ADR-0020 borrador)

    private var actividades: [String: [String: ActividadItinerario]] = [:]  // tripId -> itemId -> Actividad

    // MARK: - Almacén de chat (M6, ADR-0021 borrador)

    private var mensajesPorViaje: [String: [Int64: Mensaje]] = [:]  // tripId -> msgId -> Mensaje
    /// Contador GLOBAL (no por viaje, plan §Contrato de dominio): el cursor
    /// `id` es monotónico creciente a través de todos los viajes, igual que
    /// `generated always as identity` en la migración 0006.
    private var proximoMensajeId: Int64 = 1

    // MARK: - Almacén de fotos (M7 Task 1, ADR-0022 borrador)

    private var fotos: [String: [String: Foto]] = [:]  // tripId -> fotoId -> Foto

    // MARK: - Almacén de reservas (wedge "quién ya reservó")

    private var reservas: [String: Reserva] = [:]  // "tripId|activityId" -> Reserva

    // MARK: - Almacén de confirmaciones (dy5 "confirmaciones → auto-marca el wedge")

    private var confirmaciones: [String: Confirmacion] = [:]  // "tripId|activityId|miembro" -> Confirmacion

    public init() {}

    // MARK: - Setup para tests

    // Estos helpers escriben en los almacenes REALES (`miembrosDeViaje`, `viajes`), los
    // mismos que usa `ViajeRepositorio`. Antes escribían en dos almacenes paralelos
    // (`miembros`, `cerrados`) que NADIE MÁS leía, así que el doble de test mentía:
    // `unirsePorCodigo` no hacía miembro a nadie a ojos de `esMiembro`, `quitarMiembro`
    // no desautorizaba, y `cerrar` no cerraba nada. Por eso ninguna prueba de extremo a
    // extremo podía detectar regresiones de "miembro ACTUAL" ni de "viaje cerrado" — y
    // por eso el agujero de `CasosDeUsoVotacion.cerrar` sobrevivió a ocho PRs
    // (causa raíz identificada en la revisión integrada).

    /// Alta directa sin pasar por invitación. PRESERVA el rol y reactiva a quien salió:
    /// varios tests crean el viaje con `CasosDeUsoViaje` (que deja al creador como
    /// `.owner`) y luego llaman aquí para sembrar el resto; sobrescribir la fila
    /// degradaría al owner a `.member` y rompería la autorización que quieren probar.
    public func anadirMiembro(_ m: MiembroId, a tripId: String) {
        if var fila = miembrosDeViaje[tripId]?[m] {
            fila.leftAt = nil
            miembrosDeViaje[tripId]?[m] = fila
        } else {
            // `.distantPast`: este helper de test no recibe `ahora` (a diferencia de
            // `crearViaje`/`unirsePorCodigo`), así que no hay una fecha de alta real que
            // registrar. Usar una constante fija (en vez de `Date()`) mantiene
            // `miembroActivoMasAntiguo` determinista sin importar el orden de las
            // llamadas en un mismo test.
            miembrosDeViaje[tripId, default: [:]][m] = FilaMiembro(rol: .member, leftAt: nil, joinedAt: .distantPast)
        }
    }

    /// Marca la salida igual que `quitarMiembro` (deja `leftAt`, no borra la fila).
    public func quitarDeMembresia(_ m: MiembroId, de tripId: String) { marcarSalida(m, tripId) }   // helper de test (M5)
    public func expulsar(_ m: MiembroId, de tripId: String) { marcarSalida(m, tripId) }            // helper de test (M1)

    private func marcarSalida(_ m: MiembroId, _ tripId: String) {
        guard var fila = miembrosDeViaje[tripId]?[m] else { return }
        fila.leftAt = fila.leftAt ?? Self.marcaDeTest
        miembrosDeViaje[tripId]?[m] = fila
    }

    /// Cierra el viaje en el almacén real. Crea una ficha mínima si el test nunca llamó
    /// a `crearViaje` (el caso habitual: sembrar con `anadirMiembro` y cerrar), porque
    /// si no `viajeCerrado` seguiría devolviendo `false` y el cierre no probaría nada.
    public func cerrarViaje(_ tripId: String) {
        if let v = viajes[tripId] {
            viajes[tripId] = Viaje(id: v.id, name: v.name, baseCurrency: v.baseCurrency,
                                    createdBy: v.createdBy, closedAt: v.closedAt ?? Self.marcaDeTest)
        } else {
            viajes[tripId] = Viaje(id: tripId, name: "", baseCurrency: "EUR",
                                    createdBy: MiembroId(""), closedAt: Self.marcaDeTest)
        }
    }

    /// Fecha fija para los helpers: da igual cuál sea, solo importa que NO sea nil.
    private static let marcaDeTest = Date(timeIntervalSince1970: 0)

    // MARK: - Membresia

    /// Deriva del MISMO almacén que `ViajeRepositorio.rol`: miembro activo = existe la
    /// fila y no tiene `leftAt`. Así unirse/salir/expulsar por el camino real afectan de
    /// verdad a la autorización de los ocho módulos.
    public func esMiembro(_ m: MiembroId, de tripId: String) -> Bool {
        guard let fila = miembrosDeViaje[tripId]?[m] else { return false }
        return fila.leftAt == nil
    }

    /// Deriva del MISMO almacén que `ViajeRepositorio.cerrar`.
    public func viajeCerrado(_ tripId: String) -> Bool { viajes[tripId]?.closedAt != nil }

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
        // Historial append-only (ADR-0015 §15, bead p4b): `field: "expense"` es la
        // MISMA granularidad-stub que `RepositorioPostgres.actualizar` (el diff
        // campo-a-campo real es una mejora futura, fuera de este bead) — el doble
        // no debe mentir respecto a lo que hace producción.
        let revision = RevisionGasto(id: proximaRevisionId, expenseId: gasto.id, editedBy: actor,
                                     editedAt: Date(), field: "expense", oldValue: nil, newValue: nil)
        proximaRevisionId += 1
        revisionesPorGasto[gasto.id, default: []].append(revision)

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

    /// El `tripId` se verifica contra `datos` (defensa en profundidad, mismo
    /// criterio que el JOIN con `expenses` en `RepositorioPostgres`): un
    /// `expenseId` que no pertenece a este viaje no filtra su historial. El
    /// caso de uso YA valida esto vía `repo.gasto(id:en:)`, pero el repo no debe
    /// confiar ciegamente en el llamador.
    public func revisiones(deGasto expenseId: String, en tripId: String, limit: Int) -> [RevisionGasto] {
        guard datos[tripId]?[expenseId] != nil else { return [] }
        return Array((revisionesPorGasto[expenseId] ?? []).sorted { $0.id < $1.id }.prefix(limit))
    }

    /// Derecho al olvido RGPD (bead o1v): hard-delete GLOBAL por `editedBy`, en
    /// todos los gastos de todos los viajes — mismo criterio que el `DELETE ...
    /// WHERE edited_by = $1` de `RepositorioPostgres`.
    public func olvidarRevisionesDe(_ userId: MiembroId) -> Int {
        var borradas = 0
        for (expenseId, revisiones) in revisionesPorGasto {
            let restantes = revisiones.filter { $0.editedBy != userId }
            borradas += revisiones.count - restantes.count
            revisionesPorGasto[expenseId] = restantes
        }
        return borradas
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
    /// Dedupe estructural (ADR-0015 §5): la primera vez crea; los reintentos con la misma
    /// clave natural son `duplicado` (idempotente, no error) y devuelven el id existente.
    public func crear(_ settlement: Settlement) -> ResultadoSettle {
        if let existente = settlements.first(where: { $0.value.clave == settlement.clave }) {
            return .duplicado(id: existente.key)
        }
        let id = nuevoIdSettlement()
        settlements[id] = settlement
        ordenSettlements.append(id)
        return .creado(id: id)
    }

    public func settlement(id: String, en tripId: String) -> Settlement? {
        settlements[id].flatMap { $0.tripId == tripId ? $0 : nil }
    }

    /// Barrido de caducidad (bead 1ea): materializa como `cancelled` los `pending`
    /// vencidos. `resolvedBy` queda nil a propósito: lo caduca el sistema, no un actor.
    public func caducarPendientes(ahora: Date) -> Int {
        var n = 0
        for (id, s) in settlements where s.status == .pending && s.expiresAt < ahora {
            var caducado = s
            caducado.status = .cancelled
            caducado.resolvedAt = ahora
            settlements[id] = caducado
            n += 1
        }
        return n
    }

    public func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement,
                             por actor: MiembroId, ahora: Date, rejectReason: String?) -> ResultadoTransicion {
        guard var s = settlements[id], s.tripId == tripId else { return .noEncontrado }
        if s.status == .pending && s.expiresAt < ahora { return .caducado }
        guard s.status == .pending else { return .estadoInvalido }
        s.status = nuevo; s.resolvedBy = actor; s.resolvedAt = ahora; s.rejectReason = rejectReason
        settlements[id] = s
        return .ok
    }

    /// SIN tope (entrada de saldos, ver el puerto), pero SÍ con orden estable: antes
    /// iteraba `settlements.values`, es decir el orden arbitrario de un diccionario.
    public func confirmados(de tripId: String) -> [Settlement] {
        porEstado(tripId, .confirmed).map { $0.1 }
    }

    public func pendientes(de tripId: String, limit: Int, ahora: Date) -> [(String, Settlement)] {
        // Excluye los caducados ANTES del `prefix(limit)`, igual que el `AND expires_at
        // >= ahora` de Postgres: si no, los pending viejos-y-caducados consumirían la
        // página y taparían los activos más nuevos (bot GitHub P2).
        Array(porEstado(tripId, .pending).filter { $0.1.expiresAt >= ahora }.prefix(limit))
    }

    /// Recorre `ordenSettlements` (orden de creación) en vez de `settlements.values`
    /// (orden de diccionario, no determinista): así memoria y Postgres devuelven la
    /// MISMA secuencia y el `limit` recorta la misma página en los dos.
    private func porEstado(_ tripId: String, _ estado: EstadoSettlement) -> [(String, Settlement)] {
        ordenSettlements.compactMap { id in
            guard let s = settlements[id], s.tripId == tripId, s.status == estado else { return nil }
            return (id, s)
        }
    }

    private func nuevoIdSettlement() -> String { contadorSettlement += 1; return "set-\(contadorSettlement)" }
}

extension RepositorioEnMemoria: ViajeRepositorio {

    public func crearViaje(id: String, name: String, baseCurrency: String, creador: MiembroId, ahora: Date) -> Viaje {
        let viaje = Viaje(id: id, name: name, baseCurrency: baseCurrency, createdBy: creador, closedAt: nil)
        viajes[id] = viaje
        // El creador entra como owner en la misma operación (ADR-0018 §2): un
        // viaje sin owner no es un estado válido.
        miembrosDeViaje[id, default: [:]][creador] = FilaMiembro(rol: .owner, leftAt: nil, joinedAt: ahora)
        return viaje
    }

    public func viaje(id: String) -> Viaje? { viajes[id] }

    public func viajesDe(_ actor: MiembroId, limit: Int) -> [Viaje] {
        viajes.values
            .filter { miembrosDeViaje[$0.id]?[actor]?.leftAt == nil && miembrosDeViaje[$0.id]?[actor] != nil }
            .sorted { $0.id < $1.id }   // orden estable — el MISMO que Postgres (ORDER BY t.id)
            .prefix(limit)
            .map { $0 }
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
        miembrosDeViaje[inv.tripId, default: [:]][actor] = FilaMiembro(rol: .member, leftAt: nil, joinedAt: ahora)
        return .unido
    }

    /// Idempotente, igual que el `UPDATE ... WHERE left_at IS NULL` de Postgres: repetir
    /// la expulsión NO pisa la fecha de salida original (divergencia detectada en la
    /// revisión integrada).
    public func quitarMiembro(_ memberId: MiembroId, de tripId: String, ahora: Date) {
        guard var fila = miembrosDeViaje[tripId]?[memberId] else { return }
        fila.leftAt = fila.leftAt ?? ahora
        miembrosDeViaje[tripId]?[memberId] = fila
        // Revoca las invitaciones que ese miembro emitió (ADR-0014 §2, P1 de la revisión
        // integrada): si no, reingresaría con su propio code. Mismo efecto que el segundo
        // UPDATE de la transacción en Postgres.
        for (code, inv) in invitaciones where inv.tripId == tripId && inv.createdBy == memberId && inv.revokedAt == nil {
            invitaciones[code] = Invitacion(code: inv.code, tripId: inv.tripId, createdBy: inv.createdBy,
                                            expiresAt: inv.expiresAt, revokedAt: ahora)
        }
        // Limpia el estado de reserva de ese miembro en ESE viaje (Task 5, wedge "quién
        // ya reservó"): consistente con "expulsar revoca huella" — el mismo criterio que
        // ya aplica arriba a las invitaciones. `cadaUnoElSuyo` pierde al miembro de sus
        // estados; si era el `responsable` de un `unoParaTodos`, vuelve a quedar sin
        // asignar (visible como pendiente otra vez, no como "reservado por nadie").
        for (clave, r) in reservas where r.tripId == tripId {
            switch r.mode {
            case .cadaUnoElSuyo(var estados):
                guard estados[memberId] != nil else { continue }
                estados[memberId] = nil
                reservas[clave] = Reserva(activityId: r.activityId, tripId: r.tripId, kind: r.kind,
                                          mode: .cadaUnoElSuyo(estados: estados))
            case .unoParaTodos(let responsable, _):
                guard responsable == memberId else { continue }
                reservas[clave] = Reserva(activityId: r.activityId, tripId: r.tripId, kind: r.kind,
                                          mode: .unoParaTodos(responsable: nil, estado: .pendiente))
            }
        }
    }

    public func cerrar(tripId: String, ahora: Date) {
        guard let v = viajes[tripId] else { return }
        viajes[tripId] = Viaje(id: v.id, name: v.name, baseCurrency: v.baseCurrency, createdBy: v.createdBy, closedAt: ahora)
    }

    /// Ordena por `joinedAt` (empate por `member_id`, igual criterio estable que
    /// `miembros(de:)`) y descarta a `actor` — enmienda ADR-0018, sucesión de
    /// ownership en `salir`.
    public func miembroActivoMasAntiguo(de tripId: String, excluyendo actor: MiembroId) -> MiembroId? {
        (miembrosDeViaje[tripId] ?? [:])
            .filter { $0.value.leftAt == nil && $0.key != actor }
            .sorted { lhs, rhs in
                if lhs.value.joinedAt != rhs.value.joinedAt { return lhs.value.joinedAt < rhs.value.joinedAt }
                return lhs.key < rhs.key
            }
            .first?.key
    }

    /// No-op si `memberId` no es miembro activo — el caso de uso ya decidió a
    /// quién promover a partir de `miembroActivoMasAntiguo`, este método solo
    /// aplica el cambio.
    public func promoverAOwner(_ memberId: MiembroId, en tripId: String) {
        guard var fila = miembrosDeViaje[tripId]?[memberId], fila.leftAt == nil else { return }
        fila.rol = .owner
        miembrosDeViaje[tripId]?[memberId] = fila
    }
}

extension RepositorioEnMemoria: VotacionRepositorio {

    public func crear(_ v: Votacion) {
        votaciones[v.tripId, default: [:]][v.id] = v
    }

    public func votacion(id: String, en tripId: String) -> Votacion? {
        votaciones[tripId]?[id]
    }

    public func votacionesDe(_ tripId: String, limit: Int) -> [Votacion] {
        (votaciones[tripId] ?? [:]).values
            .sorted { $0.id < $1.id }   // orden estable — el MISMO que Postgres (ORDER BY id)
            .prefix(limit)
            .map { $0 }
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

extension RepositorioEnMemoria: ItinerarioRepositorio {

    public func crear(_ a: ActividadItinerario, ahora: Date) {
        actividades[a.tripId, default: [:]][a.id] = a
    }

    /// Ordenado por `(day, orderIndex, id)` (plan §4) — `day` es 'YYYY-MM-DD', que
    /// ordena igual como string ISO que como fecha real. El `id` es el desempate que
    /// faltaba: sin él, dos actividades del mismo día con el mismo `orderIndex`
    /// quedaban en orden arbitrario y la página nº2 podía repetir u omitir ítems.
    public func listar(_ tripId: String, limit: Int) -> [ActividadItinerario] {
        (actividades[tripId] ?? [:]).values
            .sorted { ($0.day, $0.orderIndex, $0.id) < ($1.day, $1.orderIndex, $1.id) }
            .prefix(limit)
            .map { $0 }
    }

    public func item(id: String, en tripId: String) -> ActividadItinerario? {
        actividades[tripId]?[id]
    }

    public func actualizar(_ a: ActividadItinerario, ahora: Date) {
        guard actividades[a.tripId]?[a.id] != nil else { return }
        actividades[a.tripId]![a.id] = a
    }

    public func borrar(id: String, en tripId: String) {
        actividades[tripId]?[id] = nil
    }
}

extension RepositorioEnMemoria: ChatRepositorio {

    public func enviar(tripId: String, autor: MiembroId, body: String, ahora: Date) -> Mensaje {
        let id = proximoMensajeId
        proximoMensajeId += 1
        let mensaje = Mensaje(id: id, tripId: tripId, autor: autor, body: body, deletedAt: nil, createdAt: ahora)
        mensajesPorViaje[tripId, default: [:]][id] = mensaje
        return mensaje
    }

    /// Cronológico (por `id`, que es monotónico) y filtrado a `id > since`
    /// (`since == nil` = desde el principio) — plan §Contrato de dominio.
    /// Incluye los mensajes borrados (con su marcador): el soft-delete no
    /// los saca del hilo (plan §Decisión 3).
    public func mensajes(tripId: String, since: Int64?, limit: Int) -> [Mensaje] {
        let umbral = since ?? 0
        return (mensajesPorViaje[tripId] ?? [:]).values
            .filter { $0.id > umbral }
            .sorted { $0.id < $1.id }
            .prefix(limit)
            .map { $0 }
    }

    public func mensaje(id: Int64, en tripId: String) -> Mensaje? {
        mensajesPorViaje[tripId]?[id]
    }

    /// Idempotente: borrar dos veces el mismo mensaje deja el `deletedAt` de
    /// la primera vez (mismo criterio de tombstone que el resto del módulo).
    public func borrar(id: Int64, en tripId: String, ahora: Date) {
        guard let existente = mensajesPorViaje[tripId]?[id], existente.deletedAt == nil else { return }
        mensajesPorViaje[tripId]![id] = Mensaje(id: existente.id, tripId: existente.tripId, autor: existente.autor, body: Mensaje.marcadorBorrado, deletedAt: ahora, createdAt: existente.createdAt)
    }
}

extension RepositorioEnMemoria: FotoRepositorio {

    public func crearPendiente(_ f: Foto) {
        fotos[f.tripId, default: [:]][f.id] = f
    }

    /// Idempotente (plan §Tareas): marcar lista una foto ya `ready` sigue
    /// devolviendo `true`. `false` solo si la foto no existe (o es de otro
    /// tripId) — mismo criterio "sin fuga" que el resto del módulo.
    public func marcarLista(id: String, en tripId: String) -> Bool {
        guard let existente = fotos[tripId]?[id] else { return false }
        guard existente.status != .ready else { return true }
        fotos[tripId]![id] = Foto(id: existente.id, tripId: existente.tripId, uploadedBy: existente.uploadedBy, storageKey: existente.storageKey, contentType: existente.contentType, sizeBytes: existente.sizeBytes, caption: existente.caption, status: .ready, createdAt: existente.createdAt)
        return true
    }

    public func foto(id: String, en tripId: String) -> Foto? {
        fotos[tripId]?[id]
    }

    /// `soloListas: true` filtra a `status == .ready` (plan §Tareas: las
    /// `pending` no se muestran).
    public func listar(_ tripId: String, soloListas: Bool, limit: Int) -> [Foto] {
        (fotos[tripId] ?? [:]).values
            .filter { !soloListas || $0.status == .ready }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    public func borrar(fotoId: String, en tripId: String) {
        fotos[tripId]?[fotoId] = nil
    }
}

extension RepositorioEnMemoria: ReservaRepositorio {

    private func claveReserva(_ tripId: String, _ activityId: String) -> String { "\(tripId)|\(activityId)" }

    public func upsert(_ r: Reserva, ahora: Date) {
        reservas[claveReserva(r.tripId, r.activityId)] = r
    }

    public func reserva(activityId: String, en tripId: String) -> Reserva? {
        reservas[claveReserva(tripId, activityId)]
    }

    /// SIN tope A PROPÓSITO (mismo criterio que `ItinerarioRepositorio.listar`,
    /// pero sin `limit`: el número de actividades ya está acotado por el
    /// itinerario). Orden estable por `activityId`.
    public func tablero(_ tripId: String) -> [Reserva] {
        reservas.values
            .filter { $0.tripId == tripId }
            .sorted { $0.activityId < $1.activityId }
    }

    /// Fija el estado de UN miembro (`cadaUnoElSuyo`, `miembro` no-nil) o del
    /// estado único (`unoParaTodos`, `miembro == nil`). No valida autorización
    /// ni pertenencia al viaje (eso es del caso de uso); si el miembro no
    /// estaba incluido en `cadaUnoElSuyo`, no se añade (silencioso, mismo
    /// criterio que `actualizar` de itinerario con id inexistente).
    public func marcarEstado(activityId: String, en tripId: String, miembro: MiembroId?, estado: EstadoReserva) {
        let k = claveReserva(tripId, activityId)
        guard let r = reservas[k] else { return }
        switch r.mode {
        case .cadaUnoElSuyo(var estados):
            if let m = miembro, estados[m] != nil { estados[m] = estado }
            reservas[k] = Reserva(activityId: r.activityId, tripId: r.tripId, kind: r.kind, mode: .cadaUnoElSuyo(estados: estados))
        case .unoParaTodos(let resp, _):
            reservas[k] = Reserva(activityId: r.activityId, tripId: r.tripId, kind: r.kind, mode: .unoParaTodos(responsable: resp, estado: estado))
        }
    }

    public func borrar(activityId: String, en tripId: String) {
        reservas[claveReserva(tripId, activityId)] = nil
    }

    private func claveConfirmacion(_ tripId: String, _ activityId: String, _ miembro: MiembroId) -> String {
        "\(tripId)|\(activityId)|\(miembro.raw)"
    }

    public func guardarConfirmacion(activityId: String, en tripId: String, miembro: MiembroId, _ c: Confirmacion) async throws {
        confirmaciones[claveConfirmacion(tripId, activityId, miembro)] = c
    }

    public func confirmacion(activityId: String, en tripId: String, miembro: MiembroId) async throws -> Confirmacion? {
        confirmaciones[claveConfirmacion(tripId, activityId, miembro)]
    }
}
