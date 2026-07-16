import Foundation

/// Creates/updates the `dockz` docker CLI context pointing at our socket, so
/// `docker context use dockz` (or --context dockz) talks to the Dockz engine.
enum DockerContextInstaller {
    static func ensureContext(socketPath: String) {
        guard let docker = findDockerCLI() else {
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
        guard let docker = findDockerCLI() else {
            completion?(false)
            return
        }
        runDocker(docker, ["context", "use", "dockz"]) { completion?($0) }
    }

    static func findDockerCLI() -> String? {
        let candidates = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runDocker(_ path: String, _ arguments: [String], completion: ((Bool) -> Void)?) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
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
