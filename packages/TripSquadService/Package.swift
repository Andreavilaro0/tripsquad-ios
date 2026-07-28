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
        // SigV4 del adaptador R2 (ADR-0022, bead 7n3): HMAC-SHA256 + SHA256 portables a
        // Linux (Render). Ya estaba en el grafo transitivo vía jwt-kit; se declara explícito
        // para poder `import Crypto` en TripSquadServiceCore. NO es red ni proveedor nuevo.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
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
