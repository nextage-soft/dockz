import Foundation

/// Create/pull/network endpoints (Portainer-style management).
extension DockerAPIClient {
    func postJSON(path: String, json: [String: Any]?, headers: [String: String] = [:], completion: @escaping (Result<RawHTTPCall.Response, Error>) -> Void) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        openVsock { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let connection):
                RawHTTPCall(connection: connection).request(method: "POST", path: path, body: body, headers: headers, completion: completion)
            }
        }
    }

    /// Pulls an image reference like "nginx:alpine" (progress streams until
    /// EOF; errors are reported inside the stream body). `authHeader` is the
    /// X-Registry-Auth value for private registries.
    func pullImage(reference: String, authHeader: String? = nil, completion: @escaping (String?) -> Void) {
        let (image, tag) = Self.splitReference(reference)
        let escaped = image.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? image
        let headers = authHeader.map { ["X-Registry-Auth": $0] } ?? [:]
        postJSON(path: "/images/create?fromImage=\(escaped)&tag=\(tag)", json: nil, headers: headers) { result in
            switch result {
            case .failure(let error):
                completion(error.localizedDescription)
            case .success(let response):
                let text = String(decoding: response.body, as: UTF8.self)
                if response.status >= 300 {
                    completion("HTTP \(response.status): \(text.prefix(200))")
                } else if let range = text.range(of: "\"error\":\"") {
                    let tail = text[range.upperBound...]
                    completion(String(tail.prefix(while: { $0 != "\"" })))
                } else {
                    completion(nil)
                }
            }
        }
    }

    /// Creates a container WITHOUT starting it, pulling the image if missing.
    /// Completion delivers (containerID, errorMessage).
    func createContainer(
        name: String?,
        config: [String: Any],
        pullAuthHeader: String? = nil,
        completion: @escaping (String?, String?) -> Void
    ) {
        let nameQuery = name.flatMap {
            $0.isEmpty ? nil : "?name=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)"
        } ?? ""
        postJSON(path: "/containers/create\(nameQuery)", json: config) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(nil, error.localizedDescription)
            case .success(let response) where response.status == 404:
                // Image not present locally — pull, then retry once.
                guard let image = config["Image"] as? String else {
                    completion(nil, "image missing")
                    return
                }
                self.pullImage(reference: image, authHeader: pullAuthHeader) { pullError in
                    if let pullError {
                        completion(nil, "pull failed: \(pullError)")
                        return
                    }
                    self.postJSON(path: "/containers/create\(nameQuery)", json: config) { retry in
                        completion(Self.createdID(retry), Self.createdError(retry))
                    }
                }
            case .success:
                completion(Self.createdID(result), Self.createdError(result))
            }
        }
    }

    /// Creates and starts a container; pulls the image first if it is missing.
    func createAndStartContainer(
        name: String?,
        config: [String: Any],
        pullAuthHeader: String? = nil,
        completion: @escaping (String?) -> Void
    ) {
        createContainer(name: name, config: config, pullAuthHeader: pullAuthHeader) { [weak self] id, errorMessage in
            guard let id else {
                completion(errorMessage ?? "create failed")
                return
            }
            self?.containerAction("start", id: id, completion: completion)
        }
    }

    func renameContainer(id: String, to name: String, completion: @escaping (String?) -> Void) {
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        postJSON(path: "/containers/\(id)/rename?name=\(escaped)", json: nil) { result in
            switch result {
            case .failure(let error): completion(error.localizedDescription)
            case .success(let response): completion(response.status < 300 ? nil : "rename failed: HTTP \(response.status)")
            }
        }
    }

    /// Raw inspect dictionary (used to pre-fill the edit form).
    func inspectContainerDict(id: String, completion: @escaping ([String: Any]?) -> Void) {
        requestData(method: "GET", path: "/containers/\(id)/json") { result in
            guard case .success(let response) = result, response.status == 200,
                  let dict = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(dict)
        }
    }

    private static func createdID(_ result: Result<RawHTTPCall.Response, Error>) -> String? {
        guard case .success(let response) = result, response.status < 300,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { return nil }
        return object["Id"] as? String
    }

    private static func createdError(_ result: Result<RawHTTPCall.Response, Error>) -> String? {
        switch result {
        case .failure(let error):
            return error.localizedDescription
        case .success(let response) where response.status < 300:
            return nil
        case .success(let response):
            let message = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["message"] as? String
            return message ?? "HTTP \(response.status)"
        }
    }

    func updateRestartPolicy(id: String, policy: String, completion: @escaping (String?) -> Void) {
        let body: [String: Any] = ["RestartPolicy": ["Name": policy, "MaximumRetryCount": policy == "on-failure" ? 3 : 0]]
        postJSON(path: "/containers/\(id)/update", json: body) { result in
            switch result {
            case .failure(let error): completion(error.localizedDescription)
            case .success(let response): completion(response.status < 300 ? nil : "HTTP \(response.status)")
            }
        }
    }

    // MARK: - Networks

    func listNetworks(completion: @escaping ([NetworkSummary]) -> Void) {
        requestData(method: "GET", path: "/networks") { result in
            guard case .success(let response) = result, response.status == 200,
                  let array = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
                completion([])
                return
            }
            completion(array.compactMap(NetworkSummary.init))
        }
    }

    func createNetwork(name: String, completion: @escaping (String?) -> Void) {
        postJSON(path: "/networks/create", json: ["Name": name, "Driver": "bridge"]) { result in
            switch result {
            case .failure(let error): completion(error.localizedDescription)
            case .success(let response): completion(response.status < 300 ? nil : "HTTP \(response.status)")
            }
        }
    }

    func inspectNetwork(id: String, completion: @escaping (String) -> Void) {
        requestData(method: "GET", path: "/networks/\(id)") { result in
            guard case .success(let response) = result,
                  let object = try? JSONSerialization.jsonObject(with: response.body),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
                completion("(not available)")
                return
            }
            completion(String(decoding: data, as: UTF8.self))
        }
    }

    static func splitReference(_ reference: String) -> (image: String, tag: String) {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.lastIndex(of: ":"), !trimmed[colon...].contains("/") {
            return (String(trimmed[..<colon]), String(trimmed[trimmed.index(after: colon)...]))
        }
        return (trimmed, "latest")
    }
}
