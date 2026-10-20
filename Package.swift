// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Healther",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HealtherCore", targets: ["HealtherCore"]),
        .executable(name: "healther", targets: ["healther-cli"]),
    ],
    targets: [
        // Apple platforms ship SQLite as the `SQLite3` module; Linux needs a module map.
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "HealtherCore",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            resources: [.copy("Resources/foods.sqlite")]
        ),
        .executableTarget(
            name: "healther-cli",
            dependencies: ["HealtherCore"]
        ),
        .testTarget(
            name: "HealtherCoreTests",
            dependencies: ["HealtherCore"]
        ),
    ]
)
