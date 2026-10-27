// swift-tools-version: 5.9
//
// MarDock is built entirely with SwiftPM: no opaque project files, no
// third-party dependencies. `MarDockCore` is pure Swift (it also builds and
// tests on Linux); the app, its privileged helper and its updater are
// macOS-only.
//
// To produce a signed MarDock.app run `make app` (see Makefile / scripts).

import PackageDescription

var products: [Product] = [
    .library(name: "MarDockCore", targets: ["MarDockCore"]),
]

var targets: [Target] = [
    .target(
        name: "MarDockCore",
        path: "Sources/MarDockCore"
    ),
    .testTarget(
        name: "MarDockCoreTests",
        dependencies: ["MarDockCore"],
        path: "Tests/MarDockCoreTests"
    ),
]

#if os(macOS)
products += [
    .executable(name: "MarDock", targets: ["MarDock"]),
    .executable(name: "MarDockAgent", targets: ["MarDockAgent"]),
    .executable(name: "MarDockUpdater", targets: ["MarDockUpdater"]),
]
targets += [
    // The dock itself. Runs inside the App Sandbox with no network access.
    .executableTarget(
        name: "MarDock",
        dependencies: ["MarDockCore"],
        path: "Sources/MarDock"
    ),
    // Tiny XPC helper that performs a handful of allowlisted operations the
    // sandbox forbids (quitting apps, tuning the macOS Dock). Only the app it
    // ships inside can talk to it.
    .executableTarget(
        name: "MarDockAgent",
        dependencies: ["MarDockCore"],
        path: "Sources/MarDockAgent"
    ),
    // Opt-in update checks. The only part of MarDock with network access:
    // sandboxed, it can fetch this repository's GitHub releases and nothing
    // else, and can't install anything itself.
    .executableTarget(
        name: "MarDockUpdater",
        dependencies: ["MarDockCore"],
        path: "Sources/MarDockUpdater"
    ),
]
#endif

let package = Package(
    name: "MarDock",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
