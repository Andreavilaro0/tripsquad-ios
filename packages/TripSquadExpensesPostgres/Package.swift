// swift-tools-version: 6.1
import PackageDescription

// Adaptador Postgres del módulo Expenses (capa Data, ADR-0009). Implementa los
// puertos de TripSquadExpenses contra Postgres con PostgresNIO. Aquí SÍ se permite
// Foundation y dependencias de infraestructura — es la capa de fuera.
let package = Package(
    name: "TripSquadExpensesPostgres",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TripSquadExpensesPostgres", targets: ["TripSquadExpensesPostgres"]),
    ],
    dependencies: [
        .package(path: "../TripSquadDomain"),
        .package(path: "../TripSquadExpenses"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.25.0"),
    ],
    targets: [
        .target(
            name: "TripSquadExpensesPostgres",
            dependencies: [
                .product(name: "TripSquadDomain", package: "TripSquadDomain"),
                .product(name: "TripSquadExpenses", package: "TripSquadExpenses"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .testTarget(
            name: "TripSquadExpensesPostgresTests",
            dependencies: [
                "TripSquadExpensesPostgres",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
    ]
)
