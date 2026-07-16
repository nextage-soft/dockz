import Foundation

/// Form payload shared by "Run container" and "Edit & Recreate".
struct RunContainerForm {
    var image = ""
    var name = ""
    var command = ""
    var entrypoint = ""
    var user = ""
    var workingDir = ""
    var portsText = ""      // one "host:container[/udp]" per line
    var envText = ""        // one KEY=VALUE per line
    var volumesText = ""    // one /host/path:/container/path[:ro] per line
    var labelsText = ""     // one KEY=VALUE per line
    var restartPolicy = "no"
    var network = ""
    var privileged = false
    var memoryMiB = ""      // empty = unlimited
    var cpus = ""           // empty = unlimited
}

/// Builds Docker create-API bodies from the form — either from scratch (run
/// new) or merged over a container's existing config (edit & recreate, which
/// preserves fields the form does not cover: healthcheck, caps, log opts, …).
enum ContainerConfigBuilder {
    static func buildCreateConfig(_ form: RunContainerForm) -> [String: Any] {
        var exposed: [String: Any] = [:]
        var bindings: [String: Any] = [:]
        for line in lines(form.portsText) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let containerPart = parts[1].contains("/") ? parts[1] : parts[1] + "/tcp"
            exposed[containerPart] = [String: Any]()
            var hostList = (bindings[containerPart] as? [[String: Any]]) ?? []
            hostList.append(["HostPort": parts[0]])
            bindings[containerPart] = hostList
        }

        var hostConfig: [String: Any] = [
            "PortBindings": bindings,
            "RestartPolicy": ["Name": form.restartPolicy],
            "Binds": lines(form.volumesText),
            "Privileged": form.privileged,
            "Memory": Int((Double(form.memoryMiB.trimmingCharacters(in: .whitespaces)) ?? 0) * 1024 * 1024),
            "NanoCpus": Int((Double(form.cpus.trimmingCharacters(in: .whitespaces)) ?? 0) * 1_000_000_000),
        ]
        if hostConfig["Memory"] as? Int != 0 { hostConfig["MemorySwap"] = -1 }
        let network = form.network.trimmingCharacters(in: .whitespaces)
        if !network.isEmpty { hostConfig["NetworkMode"] = network }

        var config: [String: Any] = [
            "Image": form.image.trimmingCharacters(in: .whitespaces),
            "Env": lines(form.envText),
            "Labels": keyValueDict(form.labelsText),
            "ExposedPorts": exposed,
            "HostConfig": hostConfig,
        ]
        setOrClear(&config, "Cmd", splitWords(form.command))
        setOrClear(&config, "Entrypoint", splitWords(form.entrypoint))
        let user = form.user.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty { config["User"] = user }
        let workingDir = form.workingDir.trimmingCharacters(in: .whitespaces)
        if !workingDir.isEmpty { config["WorkingDir"] = workingDir }
        return config
    }

    /// Overlays the form on top of a container's inspected config so that
    /// everything editable is replaced and everything else is preserved.
    static func mergeForEdit(base inspect: [String: Any], form: RunContainerForm) -> [String: Any] {
        var merged = (inspect["Config"] as? [String: Any]) ?? [:]
        // Runtime-generated fields that must not be pinned to the old container.
        for key in ["Hostname", "Domainname", "MacAddress", "Image"] {
            merged.removeValue(forKey: key)
        }
        var hostConfig = (inspect["HostConfig"] as? [String: Any]) ?? [:]

        let override = buildCreateConfig(form)
        let overrideHost = (override["HostConfig"] as? [String: Any]) ?? [:]
        for (key, value) in overrideHost { hostConfig[key] = value }
        if form.network.trimmingCharacters(in: .whitespaces).isEmpty {
            // "default" selection keeps whatever mode the container already had.
        }
        for (key, value) in override where key != "HostConfig" { merged[key] = value }
        if splitWords(form.command) == nil { merged.removeValue(forKey: "Cmd") }
        if splitWords(form.entrypoint) == nil { merged.removeValue(forKey: "Entrypoint") }
        if form.user.trimmingCharacters(in: .whitespaces).isEmpty { merged.removeValue(forKey: "User") }
        merged["HostConfig"] = hostConfig
        return merged
    }

    /// Pre-fills the form from GET /containers/{id}/json.
    static func formFromInspect(_ inspect: [String: Any]) -> RunContainerForm {
        var form = RunContainerForm()
        let config = (inspect["Config"] as? [String: Any]) ?? [:]
        let hostConfig = (inspect["HostConfig"] as? [String: Any]) ?? [:]

        form.image = config["Image"] as? String ?? ""
        let rawName = inspect["Name"] as? String ?? ""
        form.name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        form.command = ((config["Cmd"] as? [String]) ?? []).joined(separator: " ")
        form.entrypoint = ((config["Entrypoint"] as? [String]) ?? []).joined(separator: " ")
        form.user = config["User"] as? String ?? ""
        form.workingDir = config["WorkingDir"] as? String ?? ""
        form.envText = ((config["Env"] as? [String]) ?? []).joined(separator: "\n")
        form.labelsText = ((config["Labels"] as? [String: String]) ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")

        let portBindings = (hostConfig["PortBindings"] as? [String: Any]) ?? [:]
        form.portsText = portBindings.keys.sorted().flatMap { containerPort -> [String] in
            let hosts = (portBindings[containerPort] as? [[String: Any]]) ?? []
            return hosts.compactMap { entry in
                guard let hostPort = entry["HostPort"] as? String else { return nil }
                let suffix = containerPort.hasSuffix("/tcp") ? String(containerPort.dropLast(4)) : containerPort
                return "\(hostPort):\(suffix)"
            }
        }.joined(separator: "\n")

        var binds = (hostConfig["Binds"] as? [String]) ?? []
        if binds.isEmpty {
            binds = ((inspect["Mounts"] as? [[String: Any]]) ?? []).compactMap { mount in
                let source = (mount["Type"] as? String) == "volume"
                    ? (mount["Name"] as? String ?? "")
                    : (mount["Source"] as? String ?? "")
                guard !source.isEmpty, let destination = mount["Destination"] as? String else { return nil }
                let readonly = (mount["RW"] as? Bool ?? true) ? "" : ":ro"
                return "\(source):\(destination)\(readonly)"
            }
        }
        form.volumesText = binds.joined(separator: "\n")

        form.restartPolicy = ((hostConfig["RestartPolicy"] as? [String: Any])?["Name"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "no"
        let mode = hostConfig["NetworkMode"] as? String ?? ""
        form.network = (mode == "default" || mode == "bridge") ? "" : mode
        form.privileged = hostConfig["Privileged"] as? Bool ?? false
        let memory = hostConfig["Memory"] as? Int ?? 0
        form.memoryMiB = memory > 0 ? String(memory / (1024 * 1024)) : ""
        let nano = hostConfig["NanoCpus"] as? Int ?? 0
        form.cpus = nano > 0 ? String(Double(nano) / 1_000_000_000) : ""
        return form
    }

    // MARK: - Helpers

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func keyValueDict(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines(text) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            result[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return result
    }

    private static func splitWords(_ text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed.split(separator: " ").map(String.init)
    }

    private static func setOrClear(_ dict: inout [String: Any], _ key: String, _ value: [String]?) {
        if let value { dict[key] = value }
    }
}
