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
    dependencies: [],
    targets: [
        .target(name: "DockDomain"),
        .target(name: "DockPersistence", dependencies: ["DockDomain"]),
        .target(name: "DockPlatform", dependencies: ["DockDomain"]),
        .target(name: "DockShortcuts"),
        .executableTarget(
            name: "MenuBarDock",
            dependencies: ["DockDomain", "DockPersistence", "DockPlatform", "DockShortcuts"]
        ),
        .testTarget(name: "DockDomainTests", dependencies: ["DockDomain"]),
        .testTarget(name: "DockPersistenceTests", dependencies: ["DockPersistence", "DockDomain"]),
        .testTarget(name: "DockPlatformTests", dependencies: ["DockPlatform", "DockDomain"]),
        .testTarget(name: "DockShortcutsTests", dependencies: ["DockShortcuts"]),
        .testTarget(name: "MenuBarDockTests", dependencies: ["MenuBarDock"]),
    ],
    swiftLanguageModes: [.v6]
)
