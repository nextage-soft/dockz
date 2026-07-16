import CryptoKit
import Foundation

/// Downloads the official static `docker` CLI + compose plugin into the DockZ
/// data folder, so a fresh Mac needs neither Homebrew nor Docker Desktop.
///
/// Both artefacts are pinned by version and verified by SHA-256 before they are
/// made executable — a mismatch aborts the install rather than running an
/// unexpected binary. Downloads go straight to disk (no quarantine flag is set
/// by URLSession, so the binaries run without a Gatekeeper prompt).
enum DockerCLIInstaller {
    /// Pinned upstream artefacts. Bump the version *and* the digest together.
    struct Pin {
        let version: String
        let url: URL
        let sha256: String
    }

    /// docker.com publishes no checksum file for the static CLI, so the digest
    /// below was computed from the pinned tarball and is checked on every install.
    static let dockerPin = Pin(
        version: "29.6.1",
        url: URL(string: "https://download.docker.com/mac/static/stable/aarch64/docker-29.6.1.tgz")!,
        sha256: "2e38a0fc5e90520f32bfa4b951984f4684e46042ef855ed2c6a98f015e4284ba"
    )

    /// Compose publishes a per-asset `.sha256`; we still pin it so a silently
    /// re-tagged release cannot change what we execute.
    static let composePin = Pin(
        version: "v5.3.1",
        url: URL(string: "https://github.com/docker/compose/releases/download/v5.3.1/docker-compose-darwin-aarch64")!,
        sha256: "32691ba1196d819fa68cbdc0aad9a5569e730a35ae40c6fdd8458110ecd69488"
    )

    /// Roughly how much the install downloads — shown before the user commits.
    static let approximateDownloadMB = 48

    enum InstallError: LocalizedError {
        case downloadFailed(String)
        case digestMismatch(String)
        case extractFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let what): return "Could not download \(what)."
            case .digestMismatch(let what):
                return "\(what) failed its checksum check and was discarded. Nothing was installed."
            case .extractFailed(let what): return "Could not unpack \(what)."
            }
        }
    }

    static func isInstalled(_ paths: DockzPaths = DockzPaths()) -> Bool {
        FileManager.default.isExecutableFile(atPath: paths.managedDockerCLI.path)
    }

    /// Downloads + verifies + installs both binaries. `progress` is called on the
    /// main queue with a human-readable step; `completion` with the outcome.
    static func install(_ paths: DockzPaths = DockzPaths(),
                        progress: @escaping (String) -> Void,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let report: (String) -> Void = { message in
                DispatchQueue.main.async { progress(message) }
            }
            let finish: (Result<Void, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            do {
                try FileManager.default.createDirectory(at: paths.managedCLIDirectory,
                                                        withIntermediateDirectories: true)
                try FileManager.default.createDirectory(
                    at: paths.managedComposePlugin.deletingLastPathComponent(),
                    withIntermediateDirectories: true)

                report("Downloading docker \(dockerPin.version) (19 MB)…")
                let tarball = try download(dockerPin, named: "the docker CLI")
                defer { try? FileManager.default.removeItem(at: tarball) }

                report("Unpacking docker CLI…")
                try extractDockerBinary(from: tarball, to: paths.managedDockerCLI)

                report("Downloading compose \(composePin.version) (29 MB)…")
                let compose = try download(composePin, named: "the compose plugin")
                defer { try? FileManager.default.removeItem(at: compose) }

                report("Installing compose plugin…")
                _ = try? FileManager.default.removeItem(at: paths.managedComposePlugin)
                try FileManager.default.moveItem(at: compose, to: paths.managedComposePlugin)
                try makeExecutable(paths.managedComposePlugin)

                report("Done.")
                finish(.success(()))
            } catch {
                finish(.failure(error))
            }
        }
    }

    /// `DockZ install-docker-cli` — headless install (setup scripts, CI, and a
    /// way to verify the download path without the GUI).
    static func runCLI() -> Never {
        let paths = DockzPaths()
        try? paths.ensureBaseDirectory()
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        install(paths, progress: { print("==> \($0)") }) { result in
            if case .failure(let error) = result { failure = error }
            semaphore.signal()
        }
        // The completion hops to the main queue, so pump it rather than block it.
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if let failure {
            print("✗ \(failure.localizedDescription)")
            exit(1)
        }
        print("✓ docker \(dockerPin.version) + compose \(composePin.version) installed")
        print("  \(paths.managedDockerCLI.path)")
        print("  \(paths.managedComposePlugin.path)")
        exit(0)
    }

    static func uninstall(_ paths: DockzPaths = DockzPaths()) {
        try? FileManager.default.removeItem(at: paths.managedCLIDirectory)
        try? FileManager.default.removeItem(at: paths.managedDockerConfig)
    }

    // MARK: - Steps

    /// Downloads to a temp file and verifies its digest before returning it.
    /// Verification happens *before* the file is ever marked executable.
    private static func download(_ pin: Pin, named what: String) throws -> URL {
        let semaphore = DispatchSemaphore(value: 0)
        var downloaded: URL?
        var failure: Error?

        let task = URLSession.shared.downloadTask(with: pin.url) { url, response, error in
            defer { semaphore.signal() }
            if let error { failure = error; return }
            guard let url,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                failure = InstallError.downloadFailed(what)
                return
            }
            // The temp file vanishes when this handler returns — move it first.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("dockz-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                downloaded = destination
            } catch {
                failure = error
            }
        }
        task.resume()
        semaphore.wait()

        if let failure { throw failure }
        guard let file = downloaded else { throw InstallError.downloadFailed(what) }

        guard try digest(of: file) == pin.sha256 else {
            try? FileManager.default.removeItem(at: file)
            throw InstallError.digestMismatch(what)
        }
        return file
    }

    private static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The tarball holds a single `docker/docker`; pull just that out.
    private static func extractDockerBinary(from tarball: URL, to destination: URL) throws {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockz-untar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tarball.path, "-C", workDirectory.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw InstallError.extractFailed("the docker CLI") }

        let binary = workDirectory.appendingPathComponent("docker/docker")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw InstallError.extractFailed("the docker CLI")
        }
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: binary, to: destination)
        try makeExecutable(destination)
    }

    private static func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
