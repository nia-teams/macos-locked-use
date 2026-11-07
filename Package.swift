// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LockedUse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LockedUseKit", targets: ["LockedUseKit"]),
        .executable(name: "locked-use", targets: ["LockedUseCLI"]),
        .executable(name: "LockedUseInstaller", targets: ["LockedUseInstaller"]),
        .executable(name: "LockedUseService", targets: ["LockedUseService"]),
        .executable(name: "LockedUseGuardian", targets: ["LockedUseGuardian"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "LockedUseNative", path: "Sources/LockedUseNative", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("bsm")]),
        .target(name: "LockedUseKit", dependencies: ["LockedUseNative"], path: "Sources/LockedUseKit"),
        .executableTarget(name: "LockedUseCLI", dependencies: ["LockedUseKit"], path: "Sources/LockedUseCLI"),
        .executableTarget(name: "LockedUseInstaller", dependencies: ["LockedUseKit", "LockedUseNative"], path: "Sources/Installer"),
        .executableTarget(name: "LockedUseService", dependencies: ["LockedUseKit", "LockedUseNative"], path: "Sources/Broker"),
        .executableTarget(name: "LockedUseGuardian", dependencies: ["LockedUseKit"], path: "Sources/Guardian"),
        .testTarget(name: "LockedUseKitTests", dependencies: ["LockedUseKit"], path: "Tests/LockedUseKitTests"),
    ]
)
