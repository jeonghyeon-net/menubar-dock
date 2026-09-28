// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MenuBarDock",
    defaultLocalization: "ko",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MenuBarDock", targets: ["MenuBarDock"]),
        .library(name: "DockDomain", targets: ["DockDomain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"),
    ],
    targets: [
        .target(name: "DockDomain"),
        .target(name: "DockPersistence", dependencies: ["DockDomain"]),
        .target(name: "DockPlatform", dependencies: ["DockDomain"]),
        .executableTarget(
            name: "MenuBarDock",
            dependencies: ["DockDomain", "DockPersistence", "DockPlatform", "KeyboardShortcuts"]
        ),
        .testTarget(name: "DockDomainTests", dependencies: ["DockDomain"]),
        .testTarget(name: "DockPersistenceTests", dependencies: ["DockPersistence", "DockDomain"]),
        .testTarget(name: "DockPlatformTests", dependencies: ["DockPlatform", "DockDomain"]),
    ],
    swiftLanguageModes: [.v6]
)

