import Foundation
import Network

/// Mirrors published container ports on localhost, relaying connections to the
/// guest VM's IP address (the same trick Docker Desktop uses so that
/// `docker run -p 8080:80` is reachable at localhost:8080). Handles both TCP
/// and UDP published ports.
final class PortForwarder {
    private let queue = DispatchQueue(label: "com.nextagesoft.dockz.port-forwarder")
    private var tcpListeners: [UInt16: NWListener] = [:]
    private var udpListeners: [UInt16: NWListener] = [:]
    private var guestIP: String?

    /// Fires on an arbitrary queue with the sorted list of forwarded TCP ports
    /// (used for the menu-bar summary).
    var onPortsChanged: (([UInt16]) -> Void)?

    func setGuestIP(_ ip: String?) {
        queue.async { self.guestIP = ip }
    }

    func sync(tcp: Set<UInt16>, udp: Set<UInt16>) {
        queue.async {
            self.syncLocked(desired: tcp, listeners: &self.tcpListeners, isUDP: false)
            self.syncLocked(desired: udp, listeners: &self.udpListeners, isUDP: true)
            self.onPortsChanged?(self.tcpListeners.keys.sorted())
        }
    }

    func stopAll() {
        queue.async {
            self.tcpListeners.values.forEach { $0.cancel() }
            self.udpListeners.values.forEach { $0.cancel() }
            self.tcpListeners.removeAll()
            self.udpListeners.removeAll()
            self.onPortsChanged?([])
        }
    }

    // MARK: - Queue-confined

    private func syncLocked(desired: Set<UInt16>, listeners: inout [UInt16: NWListener], isUDP: Bool) {
        let current = Set(listeners.keys)
        guard current != desired else { return }
        for port in current.subtracting(desired) {
            listeners.removeValue(forKey: port)?.cancel()
        }
        for port in desired.subtracting(current) {
            if let listener = startListener(on: port, isUDP: isUDP) {
                listeners[port] = listener
            }
        }
    }

    private func startListener(on port: UInt16, isUDP: Bool) -> NWListener? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters: NWParameters = isUDP ? .udp : .tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        guard let listener = try? NWListener(using: parameters) else {
            NSLog("dockz: cannot listen on localhost:%d/%@ (in use?)", Int(port), isUDP ? "udp" : "tcp")
            return nil
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.handle(inbound: connection, port: port, isUDP: isUDP) }
        }
        listener.start(queue: queue)
        return listener
    }

    private func handle(inbound: NWConnection, port: UInt16, isUDP: Bool) {
        guard let guestIP, let nwPort = NWEndpoint.Port(rawValue: port) else {
            inbound.cancel()
            return
        }
        let outbound = NWConnection(host: NWEndpoint.Host(guestIP), port: nwPort,
                                    using: isUDP ? .udp : .tcp)
        TCPRelay(inbound: inbound, outbound: outbound, queue: queue).start()
    }
}
