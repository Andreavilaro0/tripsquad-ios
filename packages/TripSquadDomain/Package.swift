// swift-tools-version: 6.1
import PackageDescription

// TripSquadDomain — motor de saldos puro (ADR-0011, ADR-0015 §3).
// El target de dominio NO declara dependencias: solo usa la stdlib + Foundation
// (en la frontera, para Decimal). Es la base compartida servidor+iOS y no puede
// acoplarse a Hummingbird, Postgres ni SwiftUI (test de deps en CI, bead 9dn).
let package = Package(
    name: "TripSquadDomain",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TripSquadDomain", targets: ["TripSquadDomain"]),
    ],
    targets: [
        .target(name: "TripSquadDomain"),
        .executableTarget(
            name: "generate-golden-vectors",
            dependencies: ["TripSquadDomain"]
        ),
        .testTarget(
            name: "TripSquadDomainTests",
            dependencies: ["TripSquadDomain"]
        ),
    ]
)
