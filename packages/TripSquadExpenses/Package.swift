// swift-tools-version: 6.1
import PackageDescription

// Módulo Expenses (bounded context, ADR-0009). Capa de aplicación: casos de uso
// que orquestan el dominio contra puertos. Depende SOLO de TripSquadDomain — no
// conoce Postgres, PowerSync ni HTTP (esos son adaptadores en otros módulos).
let package = Package(
    name: "TripSquadExpenses",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TripSquadExpenses", targets: ["TripSquadExpenses"]),
    ],
    dependencies: [
        .package(path: "../TripSquadDomain"),
    ],
    targets: [
        .target(
            name: "TripSquadExpenses",
            dependencies: [.product(name: "TripSquadDomain", package: "TripSquadDomain")]
        ),
        .testTarget(
            name: "TripSquadExpensesTests",
            dependencies: ["TripSquadExpenses"]
        ),
    ]
)
