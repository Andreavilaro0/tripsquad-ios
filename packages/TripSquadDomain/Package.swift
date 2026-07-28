// swift-tools-version: 6.1
import PackageDescription

// TripSquadDomain — motor de saldos puro (ADR-0011, ADR-0015 §3).
// El target de dominio NO declara dependencias: solo usa la stdlib + Foundation
// (en la frontera, para Decimal). Es la base compartida servidor+iOS y no puede
// acoplarse a Hummingbird, Postgres ni SwiftUI (test de deps en CI, bead 9dn).
//
// PropertyBased (x-sheep) es el framework de property-based testing (ADR-0011 §7):
// aporta shrinking automático y reporta la semilla del fallo. Vive EXCLUSIVAMENTE
// en el target de tests; el target de dominio sigue sin dependencias (bead 9dn).
let package = Package(
    name: "TripSquadDomain",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TripSquadDomain", targets: ["TripSquadDomain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/x-sheep/swift-property-based.git", from: "1.0.0"),
    ],
    targets: [
        // El dominio: sin dependencias. NO añadir PropertyBased aquí (bead 9dn).
        .target(name: "TripSquadDomain"),
        .executableTarget(
            name: "generate-golden-vectors",
            dependencies: ["TripSquadDomain"]
        ),
        .testTarget(
            name: "TripSquadDomainTests",
            dependencies: [
                "TripSquadDomain",
                .product(name: "PropertyBased", package: "swift-property-based"),
            ]
        ),
    ]
)
