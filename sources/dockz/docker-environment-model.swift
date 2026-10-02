import Foundation

/// A Docker engine DockZ manages besides its own VM (Portainer calls these
/// "environments"). Management only — nothing is joined or shared.
struct DockerEnvironment: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case ssh, tls, socket
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ssh: return "SSH"
            case .tls: return "TLS"
            case .socket: return "Socket"
            }
        }
    }

    static let defaultTLSPort = 2376

    var id = UUID()
    var name: String
    var kind: Kind
    /// SSH: `user@host` or ~/.ssh/config alias. TLS: host or IP. Socket: path.
    var address: String
    /// SSH: optional (ssh/config decides). TLS: required, 2376 by convention.
    var port: Int?

    var summary: String {
        let portSuffix = port.map { ":\($0)" } ?? ""
        switch kind {
        case .ssh: return "SSH · \(address)\(portSuffix)"
        case .tls: return "TLS · \(address):\(port ?? Self.defaultTLSPort)"
        case .socket: return "Socket · \(address)"
        }
    }

    func endpoint(paths: DockzPaths = DockzPaths()) -> DockerEndpoint {
        switch kind {
        case .ssh:
            return .ssh(.init(destination: address, port: port))
        case .tls:
            return .tls(.init(host: address, port: port ?? Self.defaultTLSPort,
                              certDirectory: EnvironmentCatalog.certDirectory(for: id, paths: paths),
                              clientKey: .secureEnclave(environmentID: id)))
        case .socket:
            return .unixSocket(path: (address as NSString).expandingTildeInPath)
        }
    }

    /// nil when the configuration can be tried.
    func validationError(paths: DockzPaths = DockzPaths()) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name" }
        switch kind {
        case .ssh:
            return SSHDockerConnector.validationError(.init(destination: address, port: port))
        case .tls:
            if address.isEmpty || address.hasPrefix("-") || address.contains(where: \.isWhitespace) {
                return "Enter a host or IP"
            }
            if let port, !(1...65535).contains(port) { return "Port must be 1–65535" }
            let missing = TLSDockerConnector.missingCertificates(in: EnvironmentCatalog.certDirectory(for: id, paths: paths))
            if missing.contains("ca.pem") { return "Add the server's CA certificate (ca.pem)" }
            if !TLSClientKeyVault.hasKey(for: id, paths: paths) { return "Create this Mac's client key" }
            if missing.contains("cert.pem") { return "Add the signed client certificate" }
            return nil
        case .socket:
            return address.hasPrefix("/") || address.hasPrefix("~") ? nil : "Enter an absolute socket path"
        }
    }
}

/// What `/info` says about an engine — shown in the header and the Monitor
/// tab, and used to adapt to Windows engines.
struct EngineInfo: Equatable {
    var name: String
    var operatingSystem: String
    var osType: String          // "linux" | "windows"
    var serverVersion: String
    var cpuCount: Int
    var memoryBytes: UInt64
    var containers: Int
    var containersRunning: Int
    var images: Int

    var isWindows: Bool { osType.lowercased() == "windows" }

    init?(dict: [String: Any]) {
        guard let version = dict["ServerVersion"] as? String else { return nil }
        serverVersion = version
        name = dict["Name"] as? String ?? ""
        operatingSystem = dict["OperatingSystem"] as? String ?? ""
        osType = dict["OSType"] as? String ?? "linux"
        cpuCount = (dict["NCPU"] as? NSNumber)?.intValue ?? 0
        memoryBytes = DockerJSON.byteCount(dict["MemTotal"])
        containers = (dict["Containers"] as? NSNumber)?.intValue ?? 0
        containersRunning = (dict["ContainersRunning"] as? NSNumber)?.intValue ?? 0
        images = (dict["Images"] as? NSNumber)?.intValue ?? 0
    }
}

/// Persistence: the list lives in `environments.json` in the data folder
/// (0600; names, hosts and ports only — no secrets). Each TLS environment has
/// its own folder (0700) with the public `ca.pem` / `cert.pem` and the Secure
/// Enclave key handle; no private key file is ever stored.
enum EnvironmentCatalog {
    static func fileURL(paths: DockzPaths = DockzPaths()) -> URL {
        paths.baseDirectory.appendingPathComponent("environments.json")
    }

    static func certDirectory(for id: UUID, paths: DockzPaths = DockzPaths()) -> URL {
        paths.baseDirectory.appendingPathComponent("environments/\(id.uuidString)", isDirectory: true)
    }

    static func load(paths: DockzPaths = DockzPaths()) -> [DockerEnvironment] {
        guard let data = try? Data(contentsOf: fileURL(paths: paths)) else { return [] }
        return (try? JSONDecoder().decode([DockerEnvironment].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ environments: [DockerEnvironment], paths: DockzPaths = DockzPaths()) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(environments) else { return false }
        let url = fileURL(paths: paths)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// Copies a picked PEM file in as `fileName` (ca.pem / cert.pem).
    static func importCertificate(from source: URL, as fileName: String, for id: UUID,
                                  paths: DockzPaths = DockzPaths()) throws {
        let text = String(decoding: try Data(contentsOf: source), as: UTF8.self)
        try storeCertificate(text, as: fileName, for: id, paths: paths, sourceName: source.lastPathComponent)
    }

    /// Stores certificate text (picked or pasted). Only certificates are
    /// accepted — a private key pasted here by mistake is refused, not saved.
    static func storeCertificate(_ text: String, as fileName: String, for id: UUID,
                                 paths: DockzPaths = DockzPaths(), sourceName: String = "The text") throws {
        guard TLSDockerConnector.certificateFileNames.contains(fileName) else { return }
        if text.contains("PRIVATE KEY-----") {
            throw DockzError.socketSetupFailed("\(sourceName) contains a private key — DockZ never stores those. Use only the certificate.")
        }
        guard text.contains("-----BEGIN CERTIFICATE-----") else {
            throw DockzError.socketSetupFailed("\(sourceName) is not a PEM certificate")
        }
        let directory = certDirectory(for: id, paths: paths)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    /// Earlier builds copied a picked key.pem into the environment folder.
    /// It is deleted on launch; the environment then asks for a new
    /// Secure Enclave key. Returns the environments that lost a key file.
    @discardableResult
    static func removeLegacyKeyFiles(_ environments: [DockerEnvironment],
                                     paths: DockzPaths = DockzPaths()) -> [DockerEnvironment] {
        environments.filter { environment in
            let legacy = certDirectory(for: environment.id, paths: paths).appendingPathComponent("key.pem")
            return (try? FileManager.default.removeItem(at: legacy)) != nil
        }
    }

    static func removeData(for id: UUID, paths: DockzPaths = DockzPaths()) {
        try? FileManager.default.removeItem(at: certDirectory(for: id, paths: paths))
    }
}
