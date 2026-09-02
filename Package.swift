// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexBarCore", targets: ["CodexBarCore"]),
        .executable(name: "CodexBar", targets: ["CodexBar"]),
        .executable(name: "codexbar-diagnostics", targets: ["CodexBarDiagnostics"]),
        .executable(name: "codexbar-selftest", targets: ["CodexBarSelfTests"]),
        .executable(name: "codexbar-watcher", targets: ["CodexBarWatcher"])
    ],
    targets: [
        .target(
            name: "CodexBarCore",
            linkerSettings: [
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(name: "CodexBar", dependencies: ["CodexBarCore"]),
        .executableTarget(name: "CodexBarDiagnostics", dependencies: ["CodexBarCore"]),
        .executableTarget(name: "CodexBarSelfTests", dependencies: ["CodexBarCore"]),
        .executableTarget(name: "CodexBarWatcher", dependencies: ["CodexBarCore"])
    ],
    swiftLanguageModes: [.v5]
)
