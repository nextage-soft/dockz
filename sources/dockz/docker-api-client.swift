import Foundation
import Virtualization

/// Minimal Docker Engine API client speaking HTTP/1.1 directly over vsock
/// connections to dockerd inside the guest.
final class DockerAPIClient {
    typealias VsockConnect = (UInt32, @escaping (Result<VZVirtioSocketConnection, Error>) -> Void) -> Void

    private let connect: VsockConnect

    init(connect: @escaping VsockConnect) {
        self.connect = connect
    }

    func ping(completion: @escaping (Bool) -> Void) {
        get("/_ping") { result in
            completion((try? result.get())?.status == 200)
        }
    }

    /// Published host ports of all running containers, split by protocol.
    /// Published ports mapped to the host address they should listen on.
    typealias PortBindings = [UInt16: String]

    func listPublishedPorts(completion: @escaping (_ tcp: PortBindings, _ udp: PortBindings) -> Void) {
        get("/containers/json") { result in
            guard case .success(let response) = result, response.status == 200,
                  let containers = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
                completion([:], [:])
                return
            }
            let bindings = Self.publishedPortBindings(containers)
            completion(bindings.tcp, bindings.udp)
        }
    }

    /// Mirrors docker's own semantics: `-p 8080:80` publishes on every
    /// interface (0.0.0.0), `-p 127.0.0.1:8080:80` on loopback only. Docker
    /// lists the same port once per address family ("0.0.0.0" and "::"); any
    /// wildcard entry wins over a loopback one for the same port.
    static func publishedPortBindings(_ containers: [[String: Any]]) -> (tcp: PortBindings, udp: PortBindings) {
        var tcp: PortBindings = [:]
        var udp: PortBindings = [:]
        for container in containers {
            for entry in container["Ports"] as? [[String: Any]] ?? [] {
                guard let publicPort = entry["PublicPort"] as? Int,
                      let port = UInt16(exactly: publicPort) else { continue }
                let address = listenAddress(forDockerHostIP: entry["IP"] as? String ?? "")
                let isUDP = (entry["Type"] as? String) == "udp"
                let existing = isUDP ? udp[port] : tcp[port]
                let chosen = existing == wildcardAddress ? wildcardAddress : address
                if isUDP { udp[port] = chosen } else { tcp[port] = chosen }
            }
        }
        return (tcp, udp)
    }

    static let wildcardAddress = "0.0.0.0"
    static let loopbackAddress = "127.0.0.1"

    /// Loopback stays loopback; everything else (wildcard, IPv6 wildcard, or a
    /// specific guest-side address that has no meaning on the Mac) listens on
    /// all interfaces, like `docker run -p` does by default.
    static func listenAddress(forDockerHostIP ip: String) -> String {
        switch ip {
        case "127.0.0.1", "::1": return loopbackAddress
        default: return wildcardAddress
        }
    }

    /// Opens the /events stream. `onActivity` fires for every event payload —
    /// callers re-list containers instead of parsing individual events.
    func streamEvents(onActivity: @escaping () -> Void, onClose: @escaping () -> Void) {
        openVsock { result in
            guard case .success(let connection) = result else {
                onClose()
                return
            }
            RawHTTPCall(connection: connection).stream(
                path: "/events",
                onBodyData: { _ in onActivity() },
                onClose: onClose
            )
        }
    }

    private func get(_ path: String, completion: @escaping (Result<RawHTTPCall.Response, Error>) -> Void) {
        openVsock { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let connection):
                RawHTTPCall(connection: connection).get(path: path, completion: completion)
            }
        }
    }

    /// Opens a fresh vsock connection to dockerd (one connection per request).
    func openVsock(_ completion: @escaping (Result<VZVirtioSocketConnection, Error>) -> Void) {
        connect(DockerSocketBridge.dockerVsockPort, completion)
    }
}
