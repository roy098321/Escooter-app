// swift-tools-version:5.9
// CorckieCore: pure logic, Foundation only, so it is tested on Linux CI (ARCHITECTURE §2.1).
import PackageDescription

let package = Package(
    name: "CorckieCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CorckieCore", targets: ["CorckieCore"]),
        .library(name: "CorckieSim", targets: ["CorckieSim"])
    ],
    targets: [
        .target(name: "CorckieCore"),
        // The fake scooter (TESTING §2). Holds the only packet encoder; never linked into ScooterLink.
        .target(name: "CorckieSim", dependencies: ["CorckieCore"]),
        .testTarget(name: "CorckieCoreTests", dependencies: ["CorckieCore", "CorckieSim"])
    ],
    swiftLanguageVersions: [.v5]
)
