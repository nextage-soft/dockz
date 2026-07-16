import Foundation
import Virtualization

/// Listens on ~/.dockz/docker.sock and bridges every client connection to the
/// guest dockerd through a virtio socket connection (vsock port 2375).
/// This is what makes `docker context create dockz --docker host=unix://…` work.
final class DockerSocketBridge {
    static let dockerVsockPort: UInt32 = 2375

    typealias VsockConnect = (UInt32, @escaping (Result<VZVirtioSocketConnection, Error>) -> Void) -> Void

    private let socketPath: String
    private let vsockPort: UInt32
    private let connectVsock: VsockConnect
    private let queue = DispatchQueue(label: "com.nextagesoft.dockz.socket-bridge")
    private var listenerFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var bridges: [UUID: FDBridge] = [:]

    init(socketPath: String, vsockPort: UInt32 = DockerSocketBridge.dockerVsockPort, connectVsock: @escaping VsockConnect) {
        self.socketPath = socketPath
        self.vsockPort = vsockPort
        self.connectVsock = connectVsock
    }

    func start() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockzError.socketSetupFailed("socket() failed: \(errno)") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count <= maxLength else {
            close(fd)
            throw DockzError.socketSetupFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 64) == 0 else {
            let savedErrno = errno
            close(fd)
            throw DockzError.socketSetupFailed("bind/listen failed: \(savedErrno)")
        }

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        listenerFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        queue.async {
            self.acceptSource?.cancel()
            self.acceptSource = nil
            if self.listenerFD >= 0 {
                close(self.listenerFD)
                self.listenerFD = -1
            }
            unlink(self.socketPath)
        }
    }

    // MARK: - Connections

    private func acceptPending() {
        while true {
            let clientFD = accept(listenerFD, nil, nil)
            guard clientFD >= 0 else { return }
            connectGuest(clientFD: clientFD, attempt: 0)
        }
    }

    private func connectGuest(clientFD: Int32, attempt: Int) {
        connectVsock(vsockPort) { [weak self] result in
            guard let self else {
                close(clientFD)
                return
            }
            self.queue.async {
                switch result {
                case .success(let connection):
                    self.startBridge(clientFD: clientFD, guest: connection)
                case .failure:
                    // dockerd may still be booting — retry briefly, then drop.
                    if attempt < 3 {
                        self.queue.asyncAfter(deadline: .now() + 1.0) {
                            self.connectGuest(clientFD: clientFD, attempt: attempt + 1)
                        }
                    } else {
                        close(clientFD)
                    }
                }
            }
        }
    }

    private func startBridge(clientFD: Int32, guest connection: VZVirtioSocketConnection) {
        let id = UUID()
        let bridge = FDBridge(firstFD: clientFD, secondFD: connection.fileDescriptor) { [weak self] in
            close(clientFD)
            connection.close()
            self?.queue.async { self?.bridges.removeValue(forKey: id) }
        }
        bridges[id] = bridge
    }
}
