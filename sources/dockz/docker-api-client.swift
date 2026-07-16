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
    func listPublishedPorts(completion: @escaping (_ tcp: Set<UInt16>, _ udp: Set<UInt16>) -> Void) {
        get("/containers/json") { result in
            guard case .success(let response) = result, response.status == 200,
                  let containers = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
                completion([], [])
                return
            }
            var tcp: Set<UInt16> = []
            var udp: Set<UInt16> = []
            for container in containers {
                let portEntries = container["Ports"] as? [[String: Any]] ?? []
                for entry in portEntries {
                    guard let publicPort = entry["PublicPort"] as? Int,
                          let value = UInt16(exactly: publicPort) else { continue }
                    switch entry["Type"] as? String {
                    case "udp": udp.insert(value)
                    default: tcp.insert(value)
                    }
                }
            }
            completion(tcp, udp)
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
