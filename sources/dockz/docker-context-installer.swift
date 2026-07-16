import Foundation

/// Locates a usable `docker` binary: the user's own install wins, otherwise the
/// copy DockZ downloaded into its data folder (see `DockerCLIInstaller`).
enum DockerCLI {
    struct Resolved {
        let path: String
        /// DOCKER_CONFIG to export. Only set for the managed CLI, whose compose
        /// plugin lives beside it — a system docker keeps its own config/auth.
        let configDirectory: String?
    }

    private static let systemCandidates = [
        "/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker",
    ]

    static func resolve(_ paths: DockzPaths = DockzPaths()) -> Resolved? {
        if let system = systemCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return Resolved(path: system, configDirectory: nil)
        }
        let managed = paths.managedDockerCLI.path
        guard FileManager.default.isExecutableFile(atPath: managed) else { return nil }
        return Resolved(path: managed, configDirectory: paths.managedDockerConfig.path)
    }

    /// Environment for running the resolved CLI against the DockZ engine.
    static func environment(for resolved: Resolved, socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DOCKER_HOST"] = "unix://\(socketPath)"
        if let configDirectory = resolved.configDirectory {
            environment["DOCKER_CONFIG"] = configDirectory
        }
        return environment
    }
}

/// Creates/updates the `dockz` docker CLI context pointing at our socket, so
/// `docker context use dockz` (or --context dockz) talks to the Dockz engine.
enum DockerContextInstaller {
    static func ensureContext(socketPath: String) {
        guard let docker = DockerCLI.resolve() else {
            NSLog("dockz: docker CLI not found; skipping context setup")
            return
        }
        let hostArgument = "host=unix://\(socketPath)"
        runDocker(docker, ["context", "create", "dockz", "--docker", hostArgument]) { created in
            if !created {
                runDocker(docker, ["context", "update", "dockz", "--docker", hostArgument], completion: nil)
            }
        }
    }

    static func useContext(completion: ((Bool) -> Void)? = nil) {
        guard let docker = DockerCLI.resolve() else {
            completion?(false)
            return
        }
        runDocker(docker, ["context", "use", "dockz"]) { completion?($0) }
    }

    static func findDockerCLI() -> String? { DockerCLI.resolve()?.path }

    /// Contexts live under DOCKER_CONFIG, so the managed CLI must write them to
    /// the same config dir its compose plugin uses — otherwise `docker context
    /// use dockz` from the user's shell would not see the context we created.
    private static func runDocker(_ docker: DockerCLI.Resolved, _ arguments: [String],
                                  completion: ((Bool) -> Void)?) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: docker.path)
            process.arguments = arguments
            if let configDirectory = docker.configDirectory {
                var environment = ProcessInfo.processInfo.environment
                environment["DOCKER_CONFIG"] = configDirectory
                process.environment = environment
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                completion?(process.terminationStatus == 0)
            } catch {
                completion?(false)
            }
        }
    }
}
