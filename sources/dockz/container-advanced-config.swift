import Foundation

/// Deep container settings edited through the form's "Advanced" card —
/// network identity, health check, capabilities, runtime/devices, logging.
/// Line-based text fields use the same one-entry-per-line format as the rest
/// of `RunContainerForm`, so the existing list editors bind to them directly.
struct AdvancedContainerSettings: Equatable {
    var hostname = ""
    var dnsText = ""              // one server per line
    var extraHostsText = ""       // host=ip per line (emitted as docker's host:ip)
    var capAdd: [String] = []
    var capDrop: [String] = []
    var initProcess = false
    var readonlyRootfs = false
    var shmSizeMiB = ""           // empty = docker default (64 MiB)
    var memoryReservationMiB = "" // soft limit; empty = none
    var devicesText = ""          // /dev/host[:/dev/container[:rwm]] per line
    var sysctlsText = ""          // key=value per line
    var logDriver = ""            // empty = daemon default
    var logOptsText = ""          // key=value per line
    var healthCommand = ""        // CMD-SHELL body; empty = image default
    var healthDisabled = false
    var healthIntervalSeconds = ""
    var healthTimeoutSeconds = ""
    var healthStartPeriodSeconds = ""
    var healthRetries = ""
}

extension ContainerConfigBuilder {
    /// Capabilities offered as checkboxes: the Linux capability names people
    /// actually reach for with --cap-add / --cap-drop. Anything else already on
    /// a container is still shown (and kept) — see `capabilityChoices`.
    static let commonCapabilities = [
        "ALL", "NET_ADMIN", "NET_RAW", "NET_BIND_SERVICE", "SYS_ADMIN", "SYS_PTRACE",
        "SYS_NICE", "SYS_TIME", "SYS_RESOURCE", "SYS_MODULE", "IPC_LOCK", "MKNOD",
        "AUDIT_WRITE", "CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID", "KILL",
    ]

    /// Docker accepts both "NET_ADMIN" and "CAP_NET_ADMIN"; show one spelling.
    static func normalizedCapability(_ name: String) -> String {
        let upper = name.uppercased()
        return upper.hasPrefix("CAP_") ? String(upper.dropFirst(4)) : upper
    }

    static func capabilityChoices(including selected: [String]) -> [String] {
        let extra = selected.map(normalizedCapability).filter { !commonCapabilities.contains($0) }
        return commonCapabilities + Array(Set(extra)).sorted()
    }

    static let logDrivers = ["json-file", "local", "none", "syslog", "journald", "fluentd", "gelf"]

    /// Writes the advanced settings into a create body. Every HostConfig key is
    /// always emitted so clearing a field in Edit & Recreate really clears it
    /// (mergeForEdit overlays these onto the old HostConfig).
    static func applyAdvanced(_ a: AdvancedContainerSettings,
                              config: inout [String: Any],
                              hostConfig: inout [String: Any]) {
        let hostname = a.hostname.trimmingCharacters(in: .whitespaces)
        if !hostname.isEmpty { config["Hostname"] = hostname }

        hostConfig["Dns"] = lines(a.dnsText)
        hostConfig["ExtraHosts"] = keyValuePairs(a.extraHostsText).map { "\($0.key):\($0.value)" }
        hostConfig["CapAdd"] = a.capAdd
        hostConfig["CapDrop"] = a.capDrop
        hostConfig["Init"] = a.initProcess
        hostConfig["ReadonlyRootfs"] = a.readonlyRootfs
        hostConfig["ShmSize"] = mebibytes(a.shmSizeMiB)
        hostConfig["MemoryReservation"] = mebibytes(a.memoryReservationMiB)
        hostConfig["Devices"] = lines(a.devicesText).map(deviceMapping)
        hostConfig["Sysctls"] = Dictionary(keyValuePairs(a.sysctlsText).map { ($0.key, $0.value) },
                                           uniquingKeysWith: { _, last in last })

        let driver = a.logDriver.trimmingCharacters(in: .whitespaces)
        if !driver.isEmpty {
            let options = Dictionary(keyValuePairs(a.logOptsText).map { ($0.key, $0.value) },
                                     uniquingKeysWith: { _, last in last })
            hostConfig["LogConfig"] = ["Type": driver, "Config": options]
        }

        let command = a.healthCommand.trimmingCharacters(in: .whitespaces)
        if a.healthDisabled {
            config["Healthcheck"] = ["Test": ["NONE"]]
        } else if !command.isEmpty {
            var health: [String: Any] = ["Test": ["CMD-SHELL", command]]
            if let ns = nanoseconds(a.healthIntervalSeconds) { health["Interval"] = ns }
            if let ns = nanoseconds(a.healthTimeoutSeconds) { health["Timeout"] = ns }
            if let ns = nanoseconds(a.healthStartPeriodSeconds) { health["StartPeriod"] = ns }
            if let retries = Int(a.healthRetries.trimmingCharacters(in: .whitespaces)), retries > 0 {
                health["Retries"] = retries
            }
            config["Healthcheck"] = health
        }
    }

    /// Reads the advanced settings back out of GET /containers/{id}/json.
    static func advancedFromInspect(_ inspect: [String: Any]) -> AdvancedContainerSettings {
        var a = AdvancedContainerSettings()
        let config = (inspect["Config"] as? [String: Any]) ?? [:]
        let host = (inspect["HostConfig"] as? [String: Any]) ?? [:]

        // Docker's default hostname is the first 12 chars of the id; only an
        // explicitly set one belongs in the form (else edits would pin it).
        let hostname = config["Hostname"] as? String ?? ""
        if let id = inspect["Id"] as? String, !hostname.isEmpty, hostname != String(id.prefix(12)) {
            a.hostname = hostname
        }

        a.dnsText = ((host["Dns"] as? [String]) ?? []).joined(separator: "\n")
        a.extraHostsText = ((host["ExtraHosts"] as? [String]) ?? []).compactMap { entry in
            guard let colon = entry.firstIndex(of: ":") else { return nil }
            return "\(entry[..<colon])=\(entry[entry.index(after: colon)...])"
        }.joined(separator: "\n")
        a.capAdd = ((host["CapAdd"] as? [String]) ?? []).map(normalizedCapability)
        a.capDrop = ((host["CapDrop"] as? [String]) ?? []).map(normalizedCapability)
        a.initProcess = host["Init"] as? Bool ?? false
        a.readonlyRootfs = host["ReadonlyRootfs"] as? Bool ?? false
        a.shmSizeMiB = mebibyteText(host["ShmSize"])
        a.memoryReservationMiB = mebibyteText(host["MemoryReservation"])
        a.devicesText = ((host["Devices"] as? [[String: Any]]) ?? []).compactMap { device in
            guard let onHost = device["PathOnHost"] as? String else { return nil }
            let inContainer = device["PathInContainer"] as? String ?? onHost
            let permissions = device["CgroupPermissions"] as? String ?? "rwm"
            return inContainer == onHost && permissions == "rwm"
                ? onHost : "\(onHost):\(inContainer):\(permissions)"
        }.joined(separator: "\n")
        a.sysctlsText = ((host["Sysctls"] as? [String: String]) ?? [:])
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")

        if let log = host["LogConfig"] as? [String: Any] {
            a.logDriver = log["Type"] as? String ?? ""
            a.logOptsText = ((log["Config"] as? [String: String]) ?? [:])
                .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }

        if let health = config["Healthcheck"] as? [String: Any],
           let test = health["Test"] as? [String], let kind = test.first {
            switch kind {
            case "NONE": a.healthDisabled = true
            case "CMD-SHELL": a.healthCommand = test.dropFirst().joined(separator: " ")
            // Exec form is re-emitted as CMD-SHELL; equivalent for plain commands.
            case "CMD": a.healthCommand = test.dropFirst().joined(separator: " ")
            default: break
            }
            a.healthIntervalSeconds = secondsText(health["Interval"])
            a.healthTimeoutSeconds = secondsText(health["Timeout"])
            a.healthStartPeriodSeconds = secondsText(health["StartPeriod"])
            if let retries = (health["Retries"] as? NSNumber)?.intValue, retries > 0 {
                a.healthRetries = String(retries)
            }
        }
        return a
    }

    // MARK: - Conversions

    private static func keyValuePairs(_ text: String) -> [(key: String, value: String)] {
        lines(text).compactMap { line in
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
    }

    private static func deviceMapping(_ line: String) -> [String: Any] {
        let parts = line.split(separator: ":").map(String.init)
        return [
            "PathOnHost": parts[0],
            "PathInContainer": parts.count > 1 ? parts[1] : parts[0],
            "CgroupPermissions": parts.count > 2 ? parts[2] : "rwm",
        ]
    }

    private static func mebibytes(_ text: String) -> Int {
        Int((Double(text.trimmingCharacters(in: .whitespaces)) ?? 0) * 1024 * 1024)
    }

    private static func mebibyteText(_ value: Any?) -> String {
        let bytes = (value as? NSNumber)?.intValue ?? 0
        return bytes > 0 ? String(bytes / (1024 * 1024)) : ""
    }

    private static func nanoseconds(_ text: String) -> Int? {
        guard let seconds = Double(text.trimmingCharacters(in: .whitespaces)), seconds > 0 else { return nil }
        return Int(seconds * 1_000_000_000)
    }

    private static func secondsText(_ value: Any?) -> String {
        let ns = (value as? NSNumber)?.doubleValue ?? 0
        return ns > 0 ? String(format: "%g", ns / 1_000_000_000) : ""
    }
}
