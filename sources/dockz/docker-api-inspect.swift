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
        let systemTotal = (cpu["system_cpu_usage"] as? Double) ?? 0
        let preSystem = (precpu["system_cpu_usage"] as? Double) ?? 0
        let onlineCPUs = (cpu["online_cpus"] as? Double) ?? 1
        let cpuDelta = cpuTotal - preTotal
        let systemDelta = systemTotal - preSystem
        cpuPercent = systemDelta > 0 ? (cpuDelta / systemDelta) * onlineCPUs * 100 : 0
        memoryUsedBytes = Int64((memory["usage"] as? Double) ?? 0)
        memoryLimitBytes = Int64((memory["limit"] as? Double) ?? 0)
    }
}
