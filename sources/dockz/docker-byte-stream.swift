import Foundation
import Virtualization

/// One bidirectional byte stream carrying a single HTTP exchange with a Docker
/// engine. `RawHTTPCall` only needs a blocking file descriptor and a close, so
/// every transport (vsock to the local VM, SSH, TLS, unix socket) is reduced
/// to this shape and the HTTP code stays transport-agnostic.
protocol DockerByteStream: AnyObject {
    var fileDescriptor: Int32 { get }
    func close()
    /// Transport-side explanation when the exchange failed before any HTTP
    /// response (e.g. ssh's stderr). nil when there is nothing useful to add.
    func failureDiagnostics() -> String?
}

extension VZVirtioSocketConnection: DockerByteStream {
    func failureDiagnostics() -> String? { nil }
}

/// A socket-like file descriptor plus whatever keeps its far side alive (a
/// child process, a TLS bridge). `onClose` tears those down exactly once.
final class FileDescriptorStream: DockerByteStream {
    let fileDescriptor: Int32
    private let onClose: () -> Void
    private let diagnostics: () -> String?
    private let lock = NSLock()
    private var closed = false

    init(fileDescriptor: Int32,
         onClose: @escaping () -> Void = {},
         diagnostics: @escaping () -> String? = { nil }) {
        self.fileDescriptor = fileDescriptor
        self.onClose = onClose
        self.diagnostics = diagnostics
    }

    func close() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        Darwin.close(fileDescriptor)
        onClose()
    }

    func failureDiagnostics() -> String? { diagnostics() }

    deinit { close() }
}

/// A connected AF_UNIX stream pair: `.local` goes to `RawHTTPCall`, `.remote`
/// to whatever produces the bytes (a child's stdio, a TLS pump).
struct SocketPair {
    let local: Int32
    let remote: Int32

    static func make() throws -> SocketPair {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw DockzError.socketSetupFailed("socketpair: \(String(cString: strerror(errno)))")
        }
        for fd in fds {
            var noSigpipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        }
        return SocketPair(local: fds[0], remote: fds[1])
    }
}

/// Connects to a unix-domain socket (another engine on this Mac: Colima,
/// OrbStack, Docker Desktop).
enum UnixSocketConnector {
    static func open(path: String) throws -> DockerByteStream {
        if let problem = UnixSocketPath.problem(path) {
            throw DockzError.socketSetupFailed(problem)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockzError.socketSetupFailed("socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw DockzError.socketSetupFailed("\(path): \(reason)")
        }
        return FileDescriptorStream(fileDescriptor: fd)
    }
}
