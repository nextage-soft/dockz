import Foundation

/// Row models for the dashboard, parsed from Docker Engine API JSON.

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
}

struct ImageSummary: Identifiable, Equatable {
    let id: String
    let repoTag: String
    let sizeLabel: String
    let createdLabel: String

    var shortID: String {
        String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }

    init?(dict: [String: Any]) {
        guard let id = dict["Id"] as? String else { return nil }
        self.id = id
        let tags = (dict["RepoTags"] as? [String]) ?? []
        repoTag = tags.first(where: { $0 != "<none>:<none>" }) ?? "<dangling>"
        let size = (dict["Size"] as? Int) ?? 0
        sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        if let created = dict["Created"] as? Double {
            let formatter = RelativeDateTimeFormatter()
            createdLabel = formatter.localizedString(for: Date(timeIntervalSince1970: created), relativeTo: Date())
        } else {
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
