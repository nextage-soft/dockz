import Foundation

/// Parsed GET /containers/{id}/json for the detail page.
struct ContainerDetail {
    struct Mount: Identifiable {
        let source: String
        let destination: String
        let mode: String
        var id: String { destination }
    }

    struct PortBinding: Identifiable {
        let containerPort: String
        let hostBinding: String
        var id: String { containerPort + hostBinding }
    }

    let name: String
    let image: String
    let state: String
    let startedAt: String
    let createdAt: String
    let command: String
    let workingDir: String
    let restartPolicy: String
    let ipAddress: String
    let environment: [String]
    let labels: [String: String]
    let mounts: [Mount]
    let ports: [PortBinding]

    init(dict: [String: Any]) {
        let config = dict["Config"] as? [String: Any] ?? [:]
        let hostConfig = dict["HostConfig"] as? [String: Any] ?? [:]
        let stateDict = dict["State"] as? [String: Any] ?? [:]
        let network = dict["NetworkSettings"] as? [String: Any] ?? [:]

        let rawName = dict["Name"] as? String ?? ""
        name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        image = config["Image"] as? String ?? "?"
        state = stateDict["Status"] as? String ?? "?"
        startedAt = Self.formatDate(stateDict["StartedAt"] as? String)
        createdAt = Self.formatDate(dict["Created"] as? String)

        let entrypoint = (config["Entrypoint"] as? [String]) ?? []
        let cmd = (config["Cmd"] as? [String]) ?? []
        command = (entrypoint + cmd).joined(separator: " ")
        workingDir = config["WorkingDir"] as? String ?? ""
        restartPolicy = ((hostConfig["RestartPolicy"] as? [String: Any])?["Name"] as? String) ?? "no"

        var ip = network["IPAddress"] as? String ?? ""
        if ip.isEmpty, let networks = network["Networks"] as? [String: [String: Any]] {
            ip = networks.values.compactMap { $0["IPAddress"] as? String }.first(where: { !$0.isEmpty }) ?? ""
        }
        ipAddress = ip

        environment = (config["Env"] as? [String]) ?? []
        labels = (config["Labels"] as? [String: String]) ?? [:]

        mounts = (dict["Mounts"] as? [[String: Any]] ?? []).map { mount in
            Mount(
                source: mount["Source"] as? String ?? (mount["Name"] as? String ?? "?"),
                destination: mount["Destination"] as? String ?? "?",
                mode: (mount["RW"] as? Bool ?? true) ? "rw" : "ro"
            )
        }

        let bindings = network["Ports"] as? [String: Any] ?? [:]
        ports = bindings.keys.sorted().map { key in
            let hosts = (bindings[key] as? [[String: Any]] ?? []).compactMap { entry -> String? in
                guard let port = entry["HostPort"] as? String else { return nil }
                return "localhost:\(port)"
            }
            return PortBinding(containerPort: key, hostBinding: hosts.isEmpty ? "—" : hosts.joined(separator: ", "))
        }
    }

    private static func formatDate(_ iso: String?) -> String {
        guard let iso, !iso.hasPrefix("0001") else { return "—" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
