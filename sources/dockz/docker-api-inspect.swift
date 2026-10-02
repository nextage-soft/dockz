import Foundation

/// Inspect/stats endpoints backing the detail pages.
extension DockerAPIClient {
    private func getObject(_ path: String, completion: @escaping ([String: Any]?) -> Void) {
        requestData(method: "GET", path: path) { result in
            guard case .success(let response) = result, response.status == 200,
                  let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(object)
        }
    }

    func inspectContainer(id: String, completion: @escaping (ContainerDetail?) -> Void) {
        getObject("/containers/\(id)/json") { dict in
            completion(dict.map(ContainerDetail.init))
        }
    }

    /// One-shot stats sample (stream=false includes precpu for CPU% math).
    func containerStats(id: String, completion: @escaping (ContainerStats?) -> Void) {
        getObject("/containers/\(id)/stats?stream=false") { dict in
            completion(dict.flatMap(ContainerStats.init))
        }
    }

    /// GET /info — engine identity (OS type, version, capacity). The error
    /// text carries the transport's own reason (ssh auth, TLS verify, …).
    func engineInfo(completion: @escaping (EngineInfo?, String?) -> Void) {
        requestData(method: "GET", path: "/info") { result in
            switch result {
            case .failure(let error):
                completion(nil, error.localizedDescription)
            case .success(let response):
                guard response.status == 200,
                      let dict = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                      let info = EngineInfo(dict: dict) else {
                    return completion(nil, "unexpected /info response (HTTP \(response.status))")
                }
                completion(info, nil)
            }
        }
    }

    /// Raw stats dict for the Monitor tab — it also needs the network and
    /// block-IO counters that `ContainerStats` does not carry.
    func containerStatsRaw(id: String, completion: @escaping ([String: Any]?) -> Void) {
        getObject("/containers/\(id)/stats?stream=false", completion: completion)
    }

    /// GET /system/df — image/container/volume/build-cache sizes. Docker walks
    /// the filesystem for this, so poll it sparingly (tens of seconds).
    func systemDiskUsage(completion: @escaping ([String: Any]?) -> Void) {
        getObject("/system/df", completion: completion)
    }

    func inspectImage(id: String, completion: @escaping (String) -> Void) {
        prettyJSON("/images/\(id)/json", completion: completion)
    }

    func inspectContainerRaw(id: String, completion: @escaping (String) -> Void) {
        prettyJSON("/containers/\(id)/json", completion: completion)
    }

    private func prettyJSON(_ path: String, completion: @escaping (String) -> Void) {
        getObject(path) { dict in
            guard let dict,
                  let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
                completion("(not available)")
                return
            }
            completion(String(decoding: data, as: UTF8.self))
        }
    }
}

struct ContainerStats {
    let cpuPercent: Double
    let memoryUsedBytes: Int64
    let memoryLimitBytes: Int64

    var memoryLabel: String {
        let used = ByteCountFormatter.string(fromByteCount: memoryUsedBytes, countStyle: .memory)
        let limit = ByteCountFormatter.string(fromByteCount: memoryLimitBytes, countStyle: .memory)
        return "\(used) / \(limit)"
    }

    init?(dict: [String: Any]) {
        guard let cpu = dict["cpu_stats"] as? [String: Any],
              let precpu = dict["precpu_stats"] as? [String: Any],
              let memory = dict["memory_stats"] as? [String: Any] else { return nil }
        let cpuTotal = ((cpu["cpu_usage"] as? [String: Any])?["total_usage"] as? Double) ?? 0
        let preTotal = ((precpu["cpu_usage"] as? [String: Any])?["total_usage"] as? Double) ?? 0
        let cpuDelta = cpuTotal - preTotal
        if let systemTotal = cpu["system_cpu_usage"] as? Double {
            // Linux: share of host CPU time, scaled to cores (docker CLI formula).
            let preSystem = (precpu["system_cpu_usage"] as? Double) ?? 0
            let onlineCPUs = (cpu["online_cpus"] as? Double) ?? 1
            let systemDelta = systemTotal - preSystem
            cpuPercent = systemDelta > 0 ? (cpuDelta / systemDelta) * onlineCPUs * 100 : 0
        } else {
            // Windows: usage in 100 ns ticks against wall time × processors.
            let processors = (dict["num_procs"] as? NSNumber)?.doubleValue ?? 1
            let elapsed = Self.dockerTimestamp(dict["read"]) - Self.dockerTimestamp(dict["preread"])
            let possibleTicks = elapsed * 10_000_000 * processors
            cpuPercent = possibleTicks > 0 ? cpuDelta / possibleTicks * 100 : 0
        }
        // Linux reports usage/limit; Windows reports a private working set and no limit.
        memoryUsedBytes = Int64((memory["usage"] as? Double) ?? (memory["privateworkingset"] as? Double) ?? 0)
        memoryLimitBytes = Int64((memory["limit"] as? Double) ?? 0)
    }

    /// Seconds since 1970 for docker's RFC 3339 timestamps, which carry up to
    /// nanosecond fractions ISO8601DateFormatter won't parse.
    static func dockerTimestamp(_ value: Any?) -> Double {
        guard let text = value as? String else { return 0 }
        var whole = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix(while: \.isNumber)
            fraction = Double("0." + digits) ?? 0
            whole = String(text[..<dot]) + text[text.index(after: dot)...].drop(while: \.isNumber)
        }
        guard let date = ISO8601DateFormatter().date(from: whole) else { return 0 }
        return date.timeIntervalSince1970 + fraction
    }
}
