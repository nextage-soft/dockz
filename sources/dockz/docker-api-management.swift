import Foundation

/// Management calls used by the dashboard (containers / images / volumes).
extension DockerAPIClient {
    func requestData(method: String, path: String, completion: @escaping (Result<RawHTTPCall.Response, Error>) -> Void) {
        openVsock { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let connection):
                RawHTTPCall(connection: connection).request(method: method, path: path, completion: completion)
            }
        }
    }

    private func listJSON(_ path: String, completion: @escaping ([[String: Any]]) -> Void) {
        requestData(method: "GET", path: path) { result in
            guard case .success(let response) = result, response.status == 200,
                  let array = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
                completion([])
                return
            }
            completion(array)
        }
    }

    // MARK: - Listing

    func listAllContainers(completion: @escaping ([ContainerSummary]) -> Void) {
        listJSON("/containers/json?all=true") { completion($0.compactMap(ContainerSummary.init)) }
    }

    func listImages(completion: @escaping ([ImageSummary]) -> Void) {
        listJSON("/images/json") { completion($0.compactMap(ImageSummary.init)) }
    }

    func listVolumes(completion: @escaping ([VolumeSummary]) -> Void) {
        requestData(method: "GET", path: "/volumes") { result in
            guard case .success(let response) = result, response.status == 200,
                  let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let volumes = object["Volumes"] as? [[String: Any]] else {
                completion([])
                return
            }
            completion(volumes.compactMap(VolumeSummary.init))
        }
    }

    // MARK: - Actions (completion: error message or nil on success)

    private func expectSuccess(method: String, path: String, completion: @escaping (String?) -> Void) {
        requestData(method: method, path: path) { result in
            switch result {
            case .failure(let error):
                completion(error.localizedDescription)
            case .success(let response) where response.status < 300:
                completion(nil)
            case .success(let response):
                let message = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["message"] as? String
                completion(message ?? "HTTP \(response.status)")
            }
        }
    }

    func containerAction(_ verb: String, id: String, completion: @escaping (String?) -> Void) {
        expectSuccess(method: "POST", path: "/containers/\(id)/\(verb)", completion: completion)
    }

    func removeContainer(id: String, completion: @escaping (String?) -> Void) {
        expectSuccess(method: "DELETE", path: "/containers/\(id)?force=true&v=false", completion: completion)
    }

    func removeImage(id: String, completion: @escaping (String?) -> Void) {
        expectSuccess(method: "DELETE", path: "/images/\(id)", completion: completion)
    }

    func pruneImages(completion: @escaping (String?) -> Void) {
        expectSuccess(method: "POST", path: "/images/prune", completion: completion)
    }

    func removeVolume(name: String, completion: @escaping (String?) -> Void) {
        expectSuccess(method: "DELETE", path: "/volumes/\(name)", completion: completion)
    }

    func pruneVolumes(completion: @escaping (String?) -> Void) {
        expectSuccess(method: "POST", path: "/volumes/prune", completion: completion)
    }

    func fetchLogs(id: String, completion: @escaping (String) -> Void) {
        requestData(method: "GET", path: "/containers/\(id)/logs?stdout=true&stderr=true&tail=400") { result in
            guard case .success(let response) = result else {
                completion("(could not fetch logs)")
                return
            }
            completion(DockerLogDemuxer.demux(response.body))
        }
    }
}
