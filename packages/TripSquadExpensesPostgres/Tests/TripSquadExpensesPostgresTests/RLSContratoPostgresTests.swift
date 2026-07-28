// Test de contrato de la RLS (ADR-0030, bead 5n3) desde la capa de datos: usa el helper
// `enTransaccionConRol(actor:)` (mecanismo A+B) para demostrar que un usuario NO-MIEMBRO
// no puede leer ni escribir filas de un viaje ajeno, aunque el rol de servicio tenga GRANT.
//
// Se salta si PG_TEST != 1 (local sin Docker). En CI conecta como `postgres`; el
// `SET LOCAL role=authenticated` del helper hace que la RLS se evalúe de verdad.

import Foundation
import Testing
import Logging
import PostgresNIO
import TripSquadDomain
import TripSquadExpenses
@testable import TripSquadExpensesPostgres

@Suite("RLS por-usuario bajo rol de servicio (ADR-0030)", .enabled(if: pgHabilitado))
struct RLSContratoPostgresTests {

    let ana = MiembroId("ana"), ivan = MiembroId("ivan"), sara = MiembroId("sara")
    let logger = Logger(label: "rls.test")

    func conClienteYViaje(_ body: (PostgresClient, RepositorioPostgres, String) async throws -> Void) async throws {
        let host = ProcessInfo.processInfo.environment["PG_TEST_HOST"] ?? "localhost"
        let config = PostgresClient.Configuration(
            host: host, port: 5432, username: "postgres", password: "postgres",
            database: "tripsquad", tls: .disable)
        let client = PostgresClient(configuration: config)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let repo = RepositorioPostgres(client: client)
            let trip = "rls-" + UUID().uuidString.prefix(8)
            // Semilla como postgres (bypass RLS): Ana e Iván son miembros; Sara NO.
            try await client.query("INSERT INTO trips (id, currency_reference) VALUES (\(trip), 'EUR')")
            try await client.query("INSERT INTO trip_members (trip_id, member_id, role) VALUES (\(trip), \(ana.raw), 'owner')")
            try await client.query("INSERT INTO trip_members (trip_id, member_id, role) VALUES (\(trip), \(ivan.raw), 'member')")
            try await body(client, repo, trip)
            group.cancelAll()
        }
    }

    /// Cuenta filas de expenses visibles para `actor` (asumiendo su rol RLS).
    func gastosVisibles(_ client: PostgresClient, actor: MiembroId, trip: String) async throws -> Int {
        try await client.enTransaccionConRol(actor: actor, logger: logger) { conn in
            let rows = try await conn.query(
                "SELECT id FROM expenses WHERE trip_id = \(trip)", logger: logger)
            var n = 0
            for try await _ in rows.decode(String.self) { n += 1 }
            return n
        }
    }

    /// Un miembro (Ana) crea un gasto; un no-miembro (Sara) NO lo ve; un miembro (Iván) SÍ.
    @Test func noMiembroNoLeeGastosAjenos() async throws {
        try await conClienteYViaje { client, repo, trip in
            let id = "g-" + UUID().uuidString
            let gasto = Gasto(id: id, pagadoPor: ana, importeMinor: 3000, reparto: .igual(entre: [ana, ivan]))
            let r = try await repo.guardar(gasto, en: trip, por: ana, idempotencyKey: "\(id)-k1")
            guard case .creado = r else { Issue.record("esperaba creado, obtuve \(r)"); return }

            let vistosIvan = try await gastosVisibles(client, actor: ivan, trip: trip)
            #expect(vistosIvan == 1, "un miembro (ivan) debe ver el gasto del viaje")
            let vistosSara = try await gastosVisibles(client, actor: sara, trip: trip)
            #expect(vistosSara == 0, "un no-miembro (sara) NO debe ver ningún gasto del viaje ajeno")
        }
    }

    /// Un no-miembro (Sara) NO puede escribir en el viaje ajeno: la policy WITH CHECK de
    /// `expenses` corta el INSERT y la escritura lanza (transacción revertida).
    @Test func noMiembroNoEscribeEnViajeAjeno() async throws {
        try await conClienteYViaje { client, repo, trip in
            let id = "g-" + UUID().uuidString
            let gasto = Gasto(id: id, pagadoPor: sara, importeMinor: 500, reparto: .igual(entre: [sara]))
            await #expect(throws: (any Error).self,
                          "el INSERT de un no-miembro debe violar la policy RLS y lanzar") {
                _ = try await repo.guardar(gasto, en: trip, por: sara, idempotencyKey: "\(id)-k1")
            }
            // Y no quedó rastro: ni el gasto (rollback) ni filtración al leer como miembro.
            let vistosAna = try await gastosVisibles(client, actor: ana, trip: trip)
            #expect(vistosAna == 0, "no debe existir el gasto que sara intentó crear")
        }
    }

    /// El rol `authenticated` no debe tener BYPASSRLS (si lo tuviera, las policies ni se
    /// evaluarían — la barrera sería falsa).
    @Test func authenticatedNoTieneBypassRLS() async throws {
        try await conClienteYViaje { client, _, _ in
            let rows = try await client.query(
                "SELECT rolbypassrls FROM pg_roles WHERE rolname = 'authenticated'", logger: logger)
            var visto = false
            for try await (bypass) in rows.decode(Bool.self) {
                visto = true
                #expect(bypass == false, "authenticated NO debe tener BYPASSRLS")
            }
            #expect(visto, "el rol authenticated debe existir tras la migración 0012")
        }
    }
}
