import Foundation

/// Registry authentication helpers: the X-Registry-Auth header dockerd wants
/// for pulls, image-ref → registry host mapping, and connection testing
/// against the registry HTTP API (/v2/, Basic or Bearer token flows).
enum RegistryAuth {
    /// base64url(JSON{username,password,serveraddress}) per the Docker API.
    static func authHeader(username: String, password: String, serverAddress: String) -> String? {
        let payload: [String: String] = [
            "username": username,
            "password": password,
            "serveraddress": serverAddress,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// "postgres:17" → "docker.io"; "registry.co:5000/app:1" → "registry.co:5000".
    static func registryHost(forImageRef imageRef: String) -> String {
        let components = imageRef.split(separator: "/")
        // A registry host only exists when there is a path separator; without
        // one the whole ref is an image name (and any ':' is the tag, not a
        // port). The first component is a host only if it looks like one.
        guard components.count > 1 else { return "docker.io" }
        let first = String(components[0])
        if first.contains(".") || first.contains(":") || first == "localhost" {
            return first
        }
        return "docker.io"
    }

    /// Probes the registry and reports a human status string.
    static func testConnection(entry: RegistryEntry, password: String?, completion: @escaping (String) -> Void) {
        let scheme = entry.insecure ? "http" : "https"
        let host = entry.isDockerHub ? "registry-1.docker.io" : entry.server
        guard let url = URL(string: "\(scheme)://\(host)/v2/") else {
            completion("Invalid server")
            return
        }
        request(url, authorization: nil) { status, headers, error in
            if let error {
                completion("Unreachable — \(error)")
                return
            }
            switch status {
            case 200:
                completion("Connected (no auth required)")
            case 401:
                guard let password, !entry.username.isEmpty else {
                    completion("Requires login — no credentials saved")
                    return
                }
                let challenge = headers["www-authenticate"]?.lowercased() ?? ""
                if challenge.hasPrefix("bearer") {
                    testBearer(challenge: headers["www-authenticate"] ?? "", entry: entry, password: password, completion: completion)
                } else {
                    let basic = "Basic " + Data("\(entry.username):\(password)".utf8).base64EncodedString()
                    request(url, authorization: basic) { retryStatus, _, retryError in
                        if let retryError { completion("Unreachable — \(retryError)"); return }
                        completion(retryStatus == 200 ? "Connected" : "Auth failed (HTTP \(retryStatus))")
                    }
                }
            default:
                completion("Unexpected HTTP \(status)")
            }
        }
    }

    /// Bearer flow: fetch a token from the realm with Basic credentials.
    private static func testBearer(challenge: String, entry: RegistryEntry, password: String, completion: @escaping (String) -> Void) {
        var realm = ""
        var service = ""
        for part in challenge.replacingOccurrences(of: "Bearer ", with: "").split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            guard pair.count == 2 else { continue }
            if pair[0].lowercased() == "realm" { realm = pair[1] }
            if pair[0].lowercased() == "service" { service = pair[1] }
        }
        guard var components = URLComponents(string: realm) else {
            completion("Bad auth challenge")
            return
        }
        if !service.isEmpty {
            components.queryItems = [URLQueryItem(name: "service", value: service)]
        }
        guard let url = components.url else {
            completion("Bad auth realm")
            return
        }
        let basic = "Basic " + Data("\(entry.username):\(password)".utf8).base64EncodedString()
        request(url, authorization: basic) { status, _, error in
            if let error { completion("Unreachable — \(error)"); return }
            completion(status == 200 ? "Connected" : "Auth failed (HTTP \(status))")
        }
    }

    private static func request(
        _ url: URL,
        authorization: String?,
        completion: @escaping (Int, [String: String], String?) -> Void
    ) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                completion(0, [:], error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(0, [:], "no response")
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key.lowercased()] = value
                }
            }
            completion(http.statusCode, headers, nil)
        }.resume()
    }
}
