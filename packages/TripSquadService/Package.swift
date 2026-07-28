// swift-tools-version: 6.1
import PackageDescription

// El servicio HTTP (ADR-0009): Hummingbird 2 (ADR-0015). Cablea los casos de uso
// de Expenses con el adaptador Postgres y expone los endpoints.
//   - TripSquadServiceCore  (librería): construcción del router + rutas (testeable)
//   - TripSquadService      (ejecutable): main fino que lee config del entorno y arranca
let package = Package(
    name: "TripSquadService",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../TripSquadDomain"),
        .package(path: "../TripSquadExpenses"),
        .package(path: "../TripSquadExpensesPostgres"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.6.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.25.0"),
        // Verificación de los JWT de Supabase (ADR-0014 §1). jwt-kit NO descarga la
        // JWKS: eso lo hace AsyncHTTPClient desde el verificador (ver Auth.swift).
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.1.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        // swift-crypto (capa HTTP): SHA256 del cuerpo canónico del request (`request_hash`,
        // bead 5ln, ADR-0012 §2 → 422 al reusar la Idempotency-Key con payload distinto) y
        // HMAC-SHA256/SHA256 del SigV4 del adaptador R2 (bead 7n3, ADR-0022). El hash viaja
        // como String por el puerto; ni Domain ni el adaptador Postgres necesitan crypto.
        // Portable a Linux (Render); ya estaba en el grafo transitivo vía jwt-kit. Andrea 2026-07-28.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "TripSquadServiceCore",
            dependencies: [
                .product(name: "TripSquadDomain", package: "TripSquadDomain"),
                .product(name: "TripSquadExpenses", package: "TripSquadExpenses"),
                .product(name: "TripSquadExpensesPostgres", package: "TripSquadExpensesPostgres"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "TripSquadService",
            dependencies: [
                "TripSquadServiceCore",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
        .testTarget(
            name: "TripSquadServiceTests",
            dependencies: [
                "TripSquadServiceCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                // Los tests FIRMAN tokens ES256 de verdad (sin red, sin mocks de crypto).
                .product(name: "JWTKit", package: "jwt-kit"),
            ]
        ),
    ]
)
