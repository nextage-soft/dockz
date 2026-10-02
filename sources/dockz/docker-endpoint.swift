import Foundation

/// Where a Docker engine is and how to reach it. The local VM keeps its vsock
/// path; remote engines use SSH or mutual TLS; other engines on this Mac a
/// unix socket. The same value drives the API client and the docker CLI.
enum DockerEndpoint {
    case vsock(DockerAPIClient.VsockConnect)
    case unixSocket(path: String)
    case ssh(SSHDockerConnector.Target)
    case tls(TLSDockerConnector.Target)

    /// Opens one byte stream for one HTTP exchange. Blocking connectors run
    /// off the caller's queue.
    func open(_ completion: @escaping (Result<DockerByteStream, Error>) -> Void) {
        switch self {
        case .vsock(let connect):
            connect(DockerSocketBridge.dockerVsockPort) { result in
                completion(result.map { $0 as DockerByteStream })
            }
        case .unixSocket(let path):
            DispatchQueue.global(qos: .userInitiated).async {
                completion(Result { try UnixSocketConnector.open(path: path) })
            }
        case .ssh(let target):
            DispatchQueue.global(qos: .userInitiated).async {
                completion(Result { try SSHDockerConnector.open(target) })
            }
        case .tls(let target):
            TLSDockerConnector.open(target, completion: completion)
        }
    }

    /// Environment variables pointing the docker CLI (compose, exec shells) at
    /// this engine — the CLI's own DOCKER_HOST / TLS conventions.
    var cliEnvironment: [String: String] {
        switch self {
        case .vsock:
            // The CLI can't speak vsock; it uses the socket bridged to the VM.
            return ["DOCKER_HOST": "unix://\(DockzPaths().dockerSocket.path)"]
        case .unixSocket(let path):
            return ["DOCKER_HOST": "unix://\(path)"]
        case .ssh(let target):
            let port = target.port.map { ":\($0)" } ?? ""
            return ["DOCKER_HOST": "ssh://\(target.destination)\(port)"]
        case .tls(let target):
            switch target.clientKey {
            case .secureEnclave(let id):
                // The key can't leave the Secure Enclave, so the CLI goes
                // through DockZ's private relay socket instead.
                return ["DOCKER_HOST": "unix://\(DockerCLISocketProxy.socketPath(for: id))"]
            case .pemFile, .signer:
                let host = target.host.contains(":") ? "[\(target.host)]" : target.host
                return [
                    "DOCKER_HOST": "tcp://\(host):\(target.port)",
                    "DOCKER_TLS_VERIFY": "1",
                    "DOCKER_CERT_PATH": target.certDirectory.path,
                ]
            }
        }
    }
}
