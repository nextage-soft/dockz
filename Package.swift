// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "dockz",
    // Compile availability floor (max for swift-tools-version 5.10). The actual
    // runtime minimum is macOS 15 (Sequoia), enforced by Info.plist's
    // LSMinimumSystemVersion — every API used is available in 14+, so it is
    // safely available on the 15+ we ship to. Apple Silicon only.
    //
    // No external dependencies: everything is Apple frameworks or written here,
    // so builds are fully offline and self-contained.
    platforms: [.macOS(.v14)],
    targets: [
        // Single executable target. Tests are compiled in and run via the
        // `DockZ test` CLI subcommand (Command Line Tools does not ship XCTest,
        // so an in-process runner is the reliable option — see test-runner.swift).
        .executableTarget(
            name: "DockzApp",
            path: "sources/dockz"
        ),
    ]
)
