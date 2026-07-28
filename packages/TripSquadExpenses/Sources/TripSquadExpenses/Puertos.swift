// Puertos (interfaces) del módulo Expenses. La capa Data (Postgres) los implementa;
// los casos de uso solo hablan con estos protocolos (Clean Architecture, ADR-0009:
// las dependencias apuntan hacia dentro).
//
// El puerto ABSTRAE las decisiones que aún no están cerradas a nivel de
// infraestructura: la mecánica de idempotencia (ADR-0012), la detección de
// conflictos por ETag (ADR-0013) y los tombstones. El caso de uso no las conoce:
// solo ve el resultado tipado `ResultadoEscritura`.

import Foundation
import TripSquadDomain

/// Resultado de una escritura mutante. Modela lo que la capa de contrato traduce a
/// códigos HTTP (§0 de la guía de contrato): distingue creado / reproducido
/// (replay idempotente) / conflicto (ETag no coincide) / rechazado.
public enum ResultadoEscritura: Equatable, Sendable {
    case creado(etag: String)
    case actualizado(etag: String)
    case eliminado
    /// Reintento de algo ya ejecutado: el efecto NO se repite (idempotencia).
    case reproducido(etag: String?)
    /// El `If-Match` no coincidió: otro editó el recurso mientras tanto.
    case conflicto(serverEtag: String)
    /// Rechazo permanente (viaje cerrado, expulsado, validación): la razón se
    /// sincroniza de vuelta al cliente (dead-letter visible, ADR-0012 §4).
    case rechazado(razon: String)
}

/// Un gasto tal como está persistido, con su ETag para control de concurrencia.
public struct GastoConEtag: Equatable, Sendable {
    public let gasto: Gasto
    public let etag: String
    public init(gasto: Gasto, etag: String) {
        self.gasto = gasto
        self.etag = etag
    }
}

/// Puerto de persistencia de gastos. Todas las escrituras llevan `idempotencyKey`
/// (derivada de forma determinista en el cliente, ADR-0012 §6) para que el
/// reintento no duplique, y el `actor` que las hace (para el historial de
/// ediciones `edited_by`, ADR-0015 §15). Las actualizaciones/borrados llevan
/// `ifMatch` (ADR-0013).
///
/// La idempotencia se scopa por **(actor, idempotencyKey)** — igual que el
/// `UNIQUE (user_id, idempotency_key)` del servidor — para que un usuario no pueda
/// secuestrar la clave de otro (ADR-0012 §5, hallazgo de Codex).
public protocol GastoRepositorio: Sendable {
    /// Replay: si esta `(actor, idempotencyKey)` ya se ejecutó, devuelve su
    /// respuesta congelada. Se consulta ANTES de re-autorizar (ADR-0012): un
    /// reintento de algo ya cometido no se rechaza aunque al actor lo hayan
    /// expulsado entre intentos (hallazgo P1 de Codex).
    func respuestaPrevia(actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura?
    func guardar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, idempotencyKey: String) async throws -> ResultadoEscritura
    /// SIN tope A PROPÓSITO (misma razón que `SettlementRepositorio.confirmados`).
    /// Hoy no hay ningún `GET /expenses`: los ÚNICOS consumidores de este método son
    /// `CasosDeUsoBrujula` y el `GET .../settlement/suggestion`, y ambos lo pasan
    /// entero a `balancesConLiquidaciones`. Truncarlo no acortaría una página: haría
    /// que los saldos del viaje SALIERAN MAL, en silencio. Si algún día se expone un
    /// listado HTTP de gastos, será un método aparte con su `limit`, no este.
    /// El orden (`ORDER BY id`) sí es estable en ambos adaptadores.
    func gastos(de tripId: String) async throws -> [GastoConEtag]
    func gasto(id: String, en tripId: String) async throws -> GastoConEtag?
    func actualizar(_ gasto: Gasto, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura
    func eliminar(id: String, en tripId: String, por actor: MiembroId, ifMatch etag: String, idempotencyKey: String) async throws -> ResultadoEscritura

    /// Historial append-only de un gasto (ADR-0015 §15, bead p4b): quién, cuándo,
    /// qué campo cambió. Orden cronológico estable (`edited_at`, `id` de
    /// desempate). `limit` llega YA clampado desde el caso de uso (patrón chat).
    /// El `tripId` filtra a nivel de query (join con `expenses`): `expense_id` es
    /// una PK GLOBAL de cliente, así que sin el filtro un `expenseId` de OTRO
    /// viaje filtraría su historial entre viajes (misma fuga que
    /// `estadoDeExistente` ya corrigió para `guardar`).
    func revisiones(deGasto expenseId: String, en tripId: String, limit: Int) async throws -> [RevisionGasto]

    /// Derecho al olvido RGPD (bead o1v, DECISIÓN de Andrea 2026-07-27, ADR-0027 —
    /// enmienda a ADR-0015 §15 / ADR-0013): HARD-DELETE selectivo de
    /// `expense_revisions` por autor (`edited_by`), **NO** crypto-shredding. Borra
    /// el rastro de texto libre de ESE actor sin tocar los gastos que edita (son
    /// de OTRO dueño) ni las revisiones de otros autores. **GLOBAL**: no se scopa
    /// por `tripId` — el derecho al olvido es de la CUENTA, no de un viaje.
    /// Devuelve cuántas filas borró (auditoría/test).
    func olvidarRevisionesDe(_ userId: MiembroId) async throws -> Int
}

/// Puerto de autorización: ¿este miembro pertenece al viaje? Una sola fuente de
/// verdad (ADR-0013 §4: `trip_members`), la misma que alimentará las RLS.
public protocol Membresia: Sendable {
    func esMiembro(_ miembro: MiembroId, de tripId: String) async throws -> Bool
    func viajeCerrado(_ tripId: String) async throws -> Bool
}

/// Respuesta HTTP congelada para replay idempotente (bead 379): el código, los
/// headers relevantes (p.ej. `etag` del create de itinerario, bead 201) y los bytes
/// exactos del body de la primera ejecución de una `(actor, key)`.
public struct RespuestaCongelada: Equatable, Sendable {
    public let code: Int
    public let headers: [String: String]
    public let body: [UInt8]
    public init(code: Int, headers: [String: String] = [:], body: [UInt8]) {
        self.code = code
        self.headers = headers
        self.body = body
    }
}

/// Resultado de RECLAMAR una `(actor, key)` (patrón claim-first de Brandur,
/// ADR-0012 §2), para el puerto `Idempotencia`.
public enum ReclamoIdempotencia: Equatable, Sendable {
    /// Primera vez: el llamante ejecuta el efecto y luego llama a `congelar`.
    case reclamado
    /// Ya se ejecutó: reproducir esta respuesta EXACTA (mismo code + body), sin re-ejecutar.
    case replay(RespuestaCongelada)
    /// Otra petición con la misma `(actor, key)` sigue en vuelo (reclamada, aún sin congelar) → 409.
    case enVuelo
}

/// Idempotencia GENÉRICA a nivel de respuesta (bead 379), para los POST mutantes que
/// NO tienen ETag/If-Match ni dedupe estructural por id (chat/itinerario/votaciones/
/// viaje). A diferencia de `GastoRepositorio` —que congela un `ResultadoEscritura`
/// tipado y dedupea por id de cliente— aquí se congela el (código, bytes) de la
/// respuesta HTTP tal cual y se reproduce en el reintento. Reusa la MISMA tabla
/// `idempotency_keys` (columnas `response_code`/`response_body`) y su scope
/// `(user_id, idempotency_key)`. `reclamar` es claim-first (atómico): dos peticiones
/// concurrentes con la misma clave no ejecutan el efecto dos veces — una recibe
/// `.reclamado`, la otra `.enVuelo` (o `.replay` si la primera ya congeló).
public protocol Idempotencia: Sendable {
    func reclamar(actor: MiembroId, key: String) async throws -> ReclamoIdempotencia
    func congelar(actor: MiembroId, key: String, respuesta: RespuestaCongelada) async throws
    /// Libera un reclamo que NO llegó a congelarse (el efecto falló antes de producir
    /// respuesta): borra el hueco `.enVuelo` para que un reintento pueda volver a
    /// intentarlo en vez de quedar bloqueado con 409. No hace nada si ya estaba congelado.
    func liberar(actor: MiembroId, key: String) async throws
}

/// Resultado de CREAR una afirmación de pago (ADR-0017).
public enum ResultadoSettle: Equatable, Sendable {
    case creado(id: String)
    case duplicado(id: String)
    case rechazado(razon: String)
}

/// Resultado de una transición (confirm/reject/cancel).
public enum ResultadoTransicion: Equatable, Sendable {
    case ok
    case noAutorizado    // el actor no puede hacer esta transición
    case noEncontrado
    case estadoInvalido  // no está en `pending`
    case caducado        // pending vencido (expiresAt < ahora)
    /// Violación de una regla de negocio ajena a la máquina de estados (bead mjp): hoy
    /// solo `motivo` (rejectReason) demasiado largo. Mismo espíritu que `ErrorViaje
    /// .reglaViolada`/`ErrorVotacion.reglaViolada`, pero `ResultadoTransicion` no es un
    /// `Result` — es su propio enum de resultado (ADR-0017) — así que el código va aquí.
    case reglaViolada(String)
}

public protocol SettlementRepositorio: Sendable {
    /// Crea si la clave natural (tripId+settlementId+from+to+transferIndex) es nueva;
    /// si ya existe → `duplicado` con el id existente (dedupe ADR-0015 §5).
    func crear(_ settlement: Settlement) async throws -> ResultadoSettle
    /// Transición autorizada de `pending` a un estado terminal. La autorización (quién puede)
    /// la decide el CASO DE USO; el repo solo aplica sobre `pending` no caducado.
    func transicionar(id: String, en tripId: String, a nuevo: EstadoSettlement,
                      por actor: MiembroId, ahora: Date, rejectReason: String?) async throws -> ResultadoTransicion
    /// SIN tope A PROPÓSITO: esto NO es un listado paginable, es la entrada de
    /// `balancesConLiquidaciones`. Un `LIMIT` aquí no recortaría una página: dejaría
    /// pagos confirmados fuera del cálculo y CORROMPERÍA los saldos en silencio.
    /// Solo lleva orden estable (`created_at, id`), que sí es gratis.
    func confirmados(de tripId: String) async throws -> [Settlement]
    /// Pendientes CON su id de almacenamiento (el dominio `Settlement` no lo lleva;
    /// lo genera el repo al crear — ADR-0017, decisión Task 4). El id hace falta para
    /// que el cliente pueda confirmar/rechazar/cancelar el settlement listado.
    /// `limit` llega YA clampado desde el caso de uso (patrón chat).
    /// Pendientes NO caducados (`expiresAt >= ahora`), filtrado ANTES del `limit`: si no,
    /// los pending más viejos —los que más probablemente caducaron— consumirían la página
    /// y ocultarían pendings activos más nuevos (bot GitHub P2 sobre la paginación). El
    /// barrido físico de los caducados es un cron aparte (bead 1ea); aquí solo se excluyen.
    func pendientes(de tripId: String, limit: Int, ahora: Date) async throws -> [(String, Settlement)]
    /// Lee un settlement por id (para autorizar la transición en el caso de uso).
    func settlement(id: String, en tripId: String) async throws -> Settlement?
    /// Barrido de mantenimiento (bead 1ea, ADR-0017): pasa a `cancelled` (marcando
    /// `resolvedAt`) todos los `pending` vencidos (`expiresAt < ahora`) de TODOS los
    /// viajes, y devuelve cuántos caducó. Pensado para un cron. Idempotente: una 2ª
    /// pasada no cambia nada. La correctitud ya la da la caducidad perezosa
    /// (`transicionar`/`pendientes`); esto solo materializa el estado terminal en BD.
    func caducarPendientes(ahora: Date) async throws -> Int
}

/// Puerto de persistencia de viajes/miembros/invitaciones (ADR-0018). Firma
/// copiada literal del plan (`docs/superpowers/plans/2026-07-24-M2-onboarding.md`).
/// `rol(de:en:) -> RolMiembro?` es la ÚNICA fuente de verdad de autorización de
/// este dominio: `nil` significa "no es miembro" y es indistinguible, desde
/// fuera, de "el viaje no existe" (evita fuga de existencia).
public protocol ViajeRepositorio: Sendable {
    func crearViaje(id: String, name: String, baseCurrency: String, creador: MiembroId, ahora: Date) async throws -> Viaje
    func viaje(id: String) async throws -> Viaje?
    /// `limit` llega YA clampado desde el caso de uso (patrón chat). Orden estable
    /// por `id` en AMBOS adaptadores: `Viaje` (dominio) no lleva `createdAt`, así que
    /// ordenar por `trips.created_at` en Postgres sería un orden que el adaptador en
    /// memoria no puede reproducir — y sin orden idéntico, paginar diverge según la
    /// implementación. Se unifica al criterio que ya usaba memoria (`id`).
    func viajesDe(_ actor: MiembroId, limit: Int) async throws -> [Viaje]
    /// SIN tope: el número de miembros ya está acotado por el dominio (tope 50,
    /// ADR-0018 §8). Sí lleva orden estable por `member_id` en ambos adaptadores.
    func miembros(de tripId: String) async throws -> [(MiembroId, RolMiembro)]
    func rol(de actor: MiembroId, en tripId: String) async throws -> RolMiembro?   // nil = no miembro
    func crearInvitacion(tripId: String, por: MiembroId, code: String, expiresAt: Date) async throws -> Invitacion
    func revocarInvitacion(code: String, en tripId: String, ahora: Date) async throws -> Bool
    func unirsePorCodigo(code: String, actor: MiembroId, ahora: Date, tope: Int) async throws -> ResultadoUnirse
    func quitarMiembro(_ memberId: MiembroId, de tripId: String, ahora: Date) async throws
    func cerrar(tripId: String, ahora: Date) async throws

    /// Miembro ACTIVO más antiguo por `joined_at`, excluyendo a `actor` — usado por
    /// `CasosDeUsoViaje.salir` para elegir sucesor cuando sale el ÚLTIMO owner
    /// (enmienda ADR-0018, decisión de Andrea 2026-07-27). `miembros(de:)` no sirve
    /// para esto: ordena por `member_id`, no por antigüedad. `nil` si `actor` es el
    /// único miembro activo. Empate de `joined_at` se desempata por `member_id`
    /// (mismo criterio de orden estable que el resto del puerto).
    func miembroActivoMasAntiguo(de tripId: String, excluyendo actor: MiembroId) async throws -> MiembroId?
    /// Promueve a `owner` a un miembro ACTIVO (no-op si ya no está activo o ya lo
    /// es). Solo lo invoca el caso de uso tras decidir la sucesión — este método no
    /// valida por sí mismo que haya un owner previo que ceda el puesto.
    func promoverAOwner(_ memberId: MiembroId, en tripId: String) async throws
}

/// Puerto de persistencia de votaciones (M4, ADR-0019 borrador). Firma copiada
/// literal de `docs/design/votaciones-scope-y-plan.md`. `votar` es un UPSERT por
/// `(pollId, member)` — cambiar de opción no duplica el voto (dedupe estructural,
/// mismo criterio que `poll_votes` en `db/migrations/0001_expenses.sql`).
public protocol VotacionRepositorio: Sendable {
    func crear(_ v: Votacion) async throws
    func votacion(id: String, en tripId: String) async throws -> Votacion?
    /// `limit` llega YA clampado desde el caso de uso (patrón chat); orden estable
    /// por `id`.
    func votacionesDe(_ tripId: String, limit: Int) async throws -> [Votacion]
    func votar(pollId: String, tripId: String, member: MiembroId, choice: String, ahora: Date) async throws -> ResultadoVotar
    func resultado(pollId: String, en tripId: String) async throws -> ResultadoVotacion?
    func cerrar(pollId: String, en tripId: String, ahora: Date) async throws
}

/// Resultado de `ItinerarioRepositorio.actualizar` (bead 201): el UPDATE es
/// condicional por etag (mismo patrón atómico que `RepositorioPostgres.
/// actualizar` de gastos — el etag va en el WHERE, no se lee-antes-de-escribir).
/// `.ok` lleva la actividad actualizada con su NUEVO etag; `.conflicto` lleva
/// el etag SERVIDOR actual (para que el cliente pueda reintentar con el
/// If-Match correcto); `.noEncontrado` cubre borrada/otro tripId.
public enum ResultadoEscrituraItinerario: Equatable, Sendable {
    case ok(ActividadConEtag)
    case conflicto(serverEtag: String)
    case noEncontrado
}

/// Puerto de persistencia de itinerario (M5, ADR-0020 borrador, enmendado por
/// el bead 201 con ETag/If-Match). Firma base copiada de
/// `docs/design/itinerario-scope-y-plan.md`. `listar` devuelve las
/// actividades ordenadas por `(day, orderIndex)` — el cliente ordena además
/// por `startTime` (plan §4), fuera del alcance del dominio.
public protocol ItinerarioRepositorio: Sendable {
    /// Devuelve la actividad creada con su etag inicial (bead 201): el
    /// dominio no lo lleva, lo asigna el repositorio en cada escritura.
    func crear(_ a: ActividadItinerario, ahora: Date) async throws -> ActividadConEtag
    /// `(day, orderIndex, id)`: el `id` es el desempate que faltaba — dos
    /// actividades del mismo día con el mismo `orderIndex` salían en orden
    /// arbitrario (distinto en cada consulta de Postgres), y sin orden total la
    /// paginación no significa nada. `limit` llega YA clampado del caso de uso.
    func listar(_ tripId: String, limit: Int) async throws -> [ActividadConEtag]
    /// Lectura "cruda" sin etag: la usan `CasosDeUsoItinerario`/
    /// `CasosDeUsoReserva` solo para autorización (createdBy) y para el merge
    /// parcial del PATCH — ninguno de los dos necesita el etag.
    func item(id: String, en tripId: String) async throws -> ActividadItinerario?
    /// UPDATE condicional ATÓMICO por etag (bead 201, mismo patrón que
    /// `GastoRepositorio.actualizar`): dos ediciones concurrentes con el mismo
    /// `If-Match` no se pisan — solo una encuentra la fila con ese etag.
    func actualizar(_ a: ActividadItinerario, ifMatch etag: String, ahora: Date) async throws -> ResultadoEscrituraItinerario
    /// Borra atómicamente scopeado por membresía ACTUAL (bead 48g): la mutación solo
    /// ocurre si `actor` sigue siendo miembro del viaje EN EL MISMO statement (con lock
    /// `FOR SHARE` sobre `trip_members` para serializar contra la revocación), cerrando la
    /// ventana TOCTOU que el re-check en el caso de uso solo estrechaba.
    ///
    /// El `Bool` es «¿la MEMBRESÍA seguía vigente?», NO «¿borró una fila?»: devuelve `true`
    /// mientras el actor siga siendo miembro —aun si el recurso ya no existía o desapareció
    /// concurrentemente— para PRESERVAR la idempotencia (borrar algo ausente es éxito). Solo
    /// devuelve `false` si la membresía fue revocada → el caso de uso da `.noAutorizado`.
    /// Un conformer nuevo DEBE seguir esta semántica, no la de «fila borrada».
    func borrar(id: String, en tripId: String, por actor: MiembroId) async throws -> Bool
}

/// Puerto de persistencia de chat (M6, ADR-0021 borrador). Firma copiada
/// literal de `docs/design/chat-scope-y-plan.md`. `id` es un cursor
/// monotónico creciente (identity en Postgres) que sirve de paginación:
/// `mensajes` devuelve en orden cronológico, solo los que `id > since`
/// (`since == nil` = desde el principio), respetando `limit`.
public protocol ChatRepositorio: Sendable {
    func enviar(tripId: String, autor: MiembroId, body: String, ahora: Date) async throws -> Mensaje
    func mensajes(tripId: String, since: Int64?, limit: Int) async throws -> [Mensaje]   // cronológico, id > since
    func mensaje(id: Int64, en tripId: String) async throws -> Mensaje?
    /// Borra (soft-delete) atómicamente scopeado por membresía ACTUAL (bead 48g): ver
    /// `ItinerarioRepositorio.borrar`. El `Bool` es «¿membresía vigente?» (idempotente),
    /// NO «¿mutó una fila?»: `true` mientras el actor siga siendo miembro; `false` solo si
    /// fue revocada → `.noAutorizado`.
    func borrar(id: Int64, en tripId: String, por actor: MiembroId, ahora: Date) async throws -> Bool
}

/// Puerto de persistencia de fotos (M7 Task 1, ADR-0022 borrador). Firma
/// copiada literal de `docs/design/fotos-plan-stub.md`. `marcarLista` es
/// idempotente: repetirlo sobre una foto ya `ready` sigue devolviendo `true`
/// (mismo criterio de idempotencia que el resto del módulo, ADR-0012/0013).
public protocol FotoRepositorio: Sendable {
    func crearPendiente(_ f: Foto) async throws
    func marcarLista(id: String, en tripId: String) async throws -> Bool
    func foto(id: String, en tripId: String) async throws -> Foto?
    /// `limit` llega YA clampado del caso de uso. Aquí el tope pesa el doble que en
    /// los demás listados: `CasosDeUsoFoto.listar` pide una URL prefirmada POR FOTO,
    /// así que sin `LIMIT` N filas eran N llamadas al proveedor de storage.
    func listar(_ tripId: String, soloListas: Bool, limit: Int) async throws -> [Foto]
    /// Etiqueta `fotoId` (no `id`) a propósito: `RepositorioEnMemoria` ya
    /// implementa `ItinerarioRepositorio.borrar(id:en:)` con la misma forma
    /// `(String, String) async throws`; un selector idéntico sería una
    /// redeclaración inválida en el mismo tipo conformante.
    /// Fotos QUEDA FUERA de la atomicidad de 48g a propósito: su borrado es binario→metadato
    /// en ESE orden (evita binarios huérfanos, hallazgo M7 P2), lo que impide un delete de
    /// metadato atómico-por-membresía como único gate. `CasosDeUsoFoto.borrar` conserva el
    /// re-check de membresía en la capa de aplicación (bead iou ronda 3), suficiente aquí.
    func borrar(fotoId: String, en tripId: String) async throws
}

/// Puerto de storage de binarios (M7 Task 1, ADR-0022 borrador). La ÚNICA
/// frontera con el mundo externo de este módulo: el dominio y los casos de
/// uso no saben si detrás hay R2, Supabase Storage o un stub. El adaptador
/// real (proveedor por decidir, `docs/design/fotos-scope.md`) es un swap-in
/// sin tocar dominio ni rutas.
public protocol FotoStorage: Sendable {
    /// URL prefirmada de SUBIDA (PUT directo del cliente al storage).
    func urlDeSubida(storageKey: String, contentType: String, expiraEn: TimeInterval) async throws -> String
    /// URL prefirmada de LECTURA (temporal).
    func urlDeLectura(storageKey: String, expiraEn: TimeInterval) async throws -> String
    func borrar(storageKey: String) async throws
}

/// Puerto de persistencia de reservas (wedge "quién ya reservó", spec
/// docs/superpowers/specs/2026-07-25-wedge-reserva-por-persona-design.md). `upsert` reemplaza el
/// aspecto reserva completo de la actividad (participantes/responsable
/// incluidos), no lo mergea.
public protocol ReservaRepositorio: Sendable {
    /// Crea o REEMPLAZA el aspecto reserva de una actividad (reemplaza participantes/responsable).
    func upsert(_ r: Reserva, ahora: Date) async throws
    func reserva(activityId: String, en tripId: String) async throws -> Reserva?
    /// El tablero: todas las reservas del viaje. Sin tope (nº actividades ya acotado por el itinerario).
    /// Orden estable por `activityId`.
    func tablero(_ tripId: String) async throws -> [Reserva]
    /// Fija el estado de UN miembro (cadaUnoElSuyo, `miembro` no-nil) o del estado único
    /// (unoParaTodos, `miembro == nil`). No valida autorización (eso es del caso de uso).
    func marcarEstado(activityId: String, en tripId: String, miembro: MiembroId?, estado: EstadoReserva) async throws
    /// Quita el aspecto reserva atómicamente scopeado por membresía ACTUAL (bead 48g): ver
    /// `ItinerarioRepositorio.borrar`. El `Bool` es «¿membresía vigente?» (idempotente:
    /// quitar un aspecto ausente con membresía vigente devuelve `true`), NO «¿borró una
    /// fila?»; `false` solo si fue revocada → `.noAutorizado`.
    func borrar(activityId: String, en tripId: String, por actor: MiembroId) async throws -> Bool
    /// Guarda la confirmación extraída para UN miembro de UNA actividad (dy5).
    /// Reemplaza si ya existía (mismo criterio que `upsert` de `Reserva`).
    func guardarConfirmacion(activityId: String, en tripId: String, miembro: MiembroId, _ c: Confirmacion) async throws
    /// Lee la confirmación de un miembro; `nil` si no ha confirmado (aún) esta actividad.
    func confirmacion(activityId: String, en tripId: String, miembro: MiembroId) async throws -> Confirmacion?
    /// Guarda la confirmación Y marca el estado del miembro como `.reservado`
    /// ATÓMICAMENTE (endurecimiento a62, ADR-0028): antes eran dos llamadas de
    /// puerto sueltas (`guardarConfirmacion` + `marcarEstado`) y un fallo entre
    /// medias podía dejar "confirmación guardada + estado pendiente". El
    /// adaptador Postgres DEBE ejecutar ambas escrituras en la MISMA transacción;
    /// el adaptador en-memoria (doble de test/dev, no persiste) las hace
    /// secuencialmente dentro de su aislamiento de `actor` — documentado como
    /// aceptable porque no hay durabilidad que corromper. `miembro` es la clave
    /// canónica de la confirmación (por-actor en `cadaUnoElSuyo`; por-actividad
    /// —el responsable— en `unoParaTodos`, ADR-0028), la decide el caso de uso.
    func guardarConfirmacionYMarcarReservado(activityId: String, en tripId: String, miembro: MiembroId, _ c: Confirmacion) async throws
}
