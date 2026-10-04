// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Tendon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Tendon", targets: ["Tendon"])
    ],
    targets: [
        .executableTarget(
            name: "Tendon",
            path: "Sources/TakoLauncher",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
