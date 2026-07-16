import Foundation

/// Central layout of everything Dockz stores on disk (~/.dockz).
struct DockzPaths {
    let baseDirectory: URL

    init() {
        // Honours a user-chosen storage location (external SSD, etc.).
        baseDirectory = StorageLocation.currentRoot
    }

    /// Layout rooted somewhere else — used for per-machine VM directories.
    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    var diskImage: URL { baseDirectory.appendingPathComponent("disk.img") }
    var efiVariableStore: URL { baseDirectory.appendingPathComponent("efi-vars.fd") }
    var machineIdentifier: URL { baseDirectory.appendingPathComponent("machine-id.bin") }
    var macAddressFile: URL { baseDirectory.appendingPathComponent("mac-address.txt") }
    var consoleLog: URL { baseDirectory.appendingPathComponent("console.log") }
    var dockerSocket: URL { baseDirectory.appendingPathComponent("docker.sock") }
    var configFile: URL { baseDirectory.appendingPathComponent("config.json") }
    /// cloud-init seed ISO (cloud-image machines only; absent otherwise).
    var seedISO: URL { baseDirectory.appendingPathComponent("seed.iso") }

    var diskImageExists: Bool {
        FileManager.default.fileExists(atPath: diskImage.path)
    }

    func ensureBaseDirectory() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }
}

enum DockzError: LocalizedError {
    case vmNotRunning
    case socketSetupFailed(String)
    case httpProtocolError(String)

    var errorDescription: String? {
        switch self {
        case .vmNotRunning:
            return "The Dockz virtual machine is not running."
        case .socketSetupFailed(let detail):
            return "Could not set up the docker socket: \(detail)"
        case .httpProtocolError(let detail):
            return "Unexpected response from the Docker engine: \(detail)"
        }
    }
}
