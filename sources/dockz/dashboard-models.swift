import Foundation

/// Row models for the dashboard, parsed from Docker Engine API JSON.

enum DockerJSON {
    /// A byte count or counter from Docker. Docker reports -1 for sizes it
    /// hasn't computed (e.g. a volume's UsageData.Size); taking that as
    /// unsigned wraps to 2^64-1 and the next sum traps. Negative or missing
    /// values count as 0.
    static func byteCount(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber else { return 0 }
        let signed = number.int64Value
        return signed > 0 ? UInt64(signed) : 0
    }
}

struct ContainerSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let image: String
    let state: String    // created / running / paused / restarting / exited / dead
    let status: String   // human text, e.g. "Up 2 hours"
    let portsLabel: String

    var shortID: String { String(id.prefix(12)) }
    var isRunning: Bool { state == "running" }

    init?(dict: [String: Any]) {
        guard let id = dict["Id"] as? String else { return nil }
        self.id = id
        let rawName = (dict["Names"] as? [String])?.first ?? ""
        name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        image = dict["Image"] as? String ?? "?"
        state = dict["State"] as? String ?? "?"
        status = dict["Status"] as? String ?? ""
        let ports = (dict["Ports"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
            guard let priv = entry["PrivatePort"] as? Int else { return nil }
            let type = entry["Type"] as? String ?? "tcp"
            if let pub = entry["PublicPort"] as? Int {
                return "\(pub)→\(priv)/\(type)"
            }
            return "\(priv)/\(type)"
        }
        portsLabel = Array(Set(ports)).sorted().joined(separator: ", ")
        labels = (dict["Labels"] as? [String: String]) ?? [:]
        imageID = dict["ImageID"] as? String ?? ""
        created = Date(timeIntervalSince1970: (dict["Created"] as? NSNumber)?.doubleValue ?? 0)
        volumeNames = (dict["Mounts"] as? [[String: Any]] ?? []).compactMap { mount in
            (mount["Type"] as? String) == "volume" ? mount["Name"] as? String : nil
        }
        var publicPorts: Set<Int> = []
        for entry in (dict["Ports"] as? [[String: Any]] ?? []) {
            if (entry["Type"] as? String) == "tcp", let publicPort = entry["PublicPort"] as? Int {
                publicPorts.insert(publicPort)
            }
        }
        publicTCPPorts = publicPorts.sorted()
    }

    /// Host ports reachable at localhost (clickable in the UI).
    let publicTCPPorts: [Int]

    /// docker compose project/service labels (nil for plain containers).
    var composeProject: String? {
        labels["com.docker.compose.project"]
    }

    var composeService: String? {
        labels["com.docker.compose.service"]
    }

    let labels: [String: String]
    let imageID: String
    let created: Date
    /// Named volumes mounted (anonymous ones included, by their hash name).
    let volumeNames: [String]

    // MARK: Derived from Docker's status text

    enum Health: String {
        case healthy, unhealthy, starting
    }

    /// Docker appends "(healthy)", "(unhealthy)" or "(health: starting)" to
    /// the status of containers that define a healthcheck.
    var health: Health? {
        if status.hasSuffix("(healthy)") { return .healthy }
        if status.hasSuffix("(unhealthy)") { return .unhealthy }
        if status.hasSuffix("(health: starting)") { return .starting }
        return nil
    }

    /// The status without the health suffix (health gets its own chip).
    var statusText: String {
        guard let open = status.lastIndex(of: "("), health != nil else { return status }
        return status[..<open].trimmingCharacters(in: .whitespaces)
    }

    /// "Exited (137) 2 hours ago" → 137.
    var exitCode: Int? {
        guard state == "exited", let open = status.firstIndex(of: "("),
              let close = status[open...].firstIndex(of: ")") else { return nil }
        return Int(status[status.index(after: open)..<close])
    }

    /// Ended on its own with a failure. A clean exit (0) or death by the
    /// signals `docker stop` / Ctrl-C send — 128+SIGINT(2), +SIGKILL(9),
    /// +SIGTERM(15) — counts as stopped, not crashed.
    var isCrashed: Bool {
        if state == "dead" { return true }
        guard let code = exitCode else { return false }
        return ![0, 130, 137, 143].contains(code)
    }

    /// Needs a look: crashed, unhealthy, or stuck restarting.
    var hasProblem: Bool {
        isCrashed || health == .unhealthy || state == "restarting"
    }

    /// State shown on the chip: "crashed" separates failures from stops.
    var displayState: String { isCrashed ? "crashed" : state }

    /// A container whose image is only an ID (untagged / since re-tagged)
    /// shows a short form instead of 71 characters of sha256.
    var imageLabel: String {
        guard image.hasPrefix("sha256:") else { return image }
        return "untagged " + image.dropFirst("sha256:".count).prefix(12)
    }
}

struct ImageSummary: Identifiable, Equatable {
    let id: String
    let repoTag: String
    let sizeLabel: String
    let createdLabel: String
    let sizeBytes: Int
    let created: Date

    var isDangling: Bool { repoTag == "<dangling>" }

    var shortID: String {
        String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }

    init?(dict: [String: Any]) {
        guard let id = dict["Id"] as? String else { return nil }
        self.id = id
        let tags = (dict["RepoTags"] as? [String]) ?? []
        repoTag = tags.first(where: { $0 != "<none>:<none>" }) ?? "<dangling>"
        let size = Int(clamping: DockerJSON.byteCount(dict["Size"]))
        sizeBytes = size
        sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        if let created = (dict["Created"] as? NSNumber)?.doubleValue {
            self.created = Date(timeIntervalSince1970: created)
            let formatter = RelativeDateTimeFormatter()
            createdLabel = formatter.localizedString(for: self.created, relativeTo: Date())
        } else {
            self.created = .distantPast
            createdLabel = ""
        }
    }
}

struct VolumeSummary: Identifiable, Equatable {
    let name: String
    let driver: String
    let mountpoint: String

    var id: String { name }

    init?(dict: [String: Any]) {
        guard let name = dict["Name"] as? String else { return nil }
        self.name = name
        driver = dict["Driver"] as? String ?? ""
        mountpoint = dict["Mountpoint"] as? String ?? ""
    }
}

struct NetworkSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let driver: String
    let scope: String

    var shortID: String { String(id.prefix(12)) }
    var isBuiltin: Bool { ["bridge", "host", "none"].contains(name) }

    init?(dict: [String: Any]) {
        guard let id = dict["Id"] as? String, let name = dict["Name"] as? String else { return nil }
        self.id = id
        self.name = name
        driver = dict["Driver"] as? String ?? ""
        scope = dict["Scope"] as? String ?? ""
    }
}

/// Docker log endpoints return a multiplexed stream when the container has no
/// TTY: 8-byte frame headers [stream, 0, 0, 0, sizeBE(4)] followed by payload.
enum DockerLogDemuxer {
    static func demux(_ data: Data) -> String {
        // TTY containers return the raw stream — no frame headers.
        if data.count < 8 || (data[0] > 2 || data[1] != 0 || data[2] != 0 || data[3] != 0) {
            return String(decoding: data, as: UTF8.self)
        }
        var output = Data()
        var index = 0
        while index + 8 <= data.count {
            let size = Int(data[index + 4]) << 24 | Int(data[index + 5]) << 16
                | Int(data[index + 6]) << 8 | Int(data[index + 7])
            let payloadStart = index + 8
            let payloadEnd = min(payloadStart + size, data.count)
            guard payloadStart <= payloadEnd else { break }
            output.append(data.subdata(in: payloadStart..<payloadEnd))
            index = payloadEnd
            if size == 0 { break }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
