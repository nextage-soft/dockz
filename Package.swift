// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "dockz",
    // Compile floor = runtime floor: macOS 15 (Sequoia), also enforced by
    // Info.plist's LSMinimumSystemVersion. Keeping the two equal lets 15-only
    // APIs be used without per-call availability checks. Apple Silicon only.
    //
    // One external dependency, Apple's own swift-nio-ssl (BoringSSL): it is
    // the only TLS stack on macOS that lets a TLS environment's client key
    // stay inside the Secure Enclave and be used through a signing callback
    // (Network.framework only accepts keychain identities, which for
    // biometry-gated keys require a provisioning profile). Exact pins keep
    // builds reproducible.
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
    ],
    targets: [
        // Single executable target. Tests are compiled in and run via the
        // `DockZ test` CLI subcommand (Command Line Tools does not ship XCTest,
        // so an in-process runner is the reliable option — see test-runner.swift).
        .executableTarget(
            name: "DockzApp",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "sources/dockz"
        ),
    ],
    // Swift 5 language mode: tools 6.0 is needed for the .v15 platform only,
    // not for Swift 6's strict-concurrency migration.
    swiftLanguageModes: [.v5]
)
