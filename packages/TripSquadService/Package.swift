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
            ]
        ),
        .executableTarget(
            name: "TripSquadService",
            dependencies: ["TripSquadServiceCore"]
        ),
        .testTarget(
            name: "TripSquadServiceTests",
            dependencies: [
                "TripSquadServiceCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
