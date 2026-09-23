import Foundation
import Network

/// Mirrors published container ports on the Mac, relaying connections to the
/// guest VM's IP address (the same trick Docker Desktop uses so that
/// `docker run -p 8080:80` is reachable at localhost:8080 — and, like docker,
/// from the network too, unless the port was published on 127.0.0.1).
/// Handles both TCP and UDP published ports.
final class PortForwarder {
    private let queue = DispatchQueue(label: "com.nextagesoft.dockz.port-forwarder")
    private var tcpListeners: [UInt16: NWListener] = [:]
    private var udpListeners: [UInt16: NWListener] = [:]
    /// Address each live listener is bound to, so a binding change rebinds.
    private var boundAddresses: [String: String] = [:]
    private var guestIP: String?

    /// Fires on an arbitrary queue with the sorted list of forwarded TCP ports
    /// (used for the menu-bar summary).
    var onPortsChanged: (([UInt16]) -> Void)?

    func setGuestIP(_ ip: String?) {
        queue.async { self.guestIP = ip }
    }

    func sync(tcp: DockerAPIClient.PortBindings, udp: DockerAPIClient.PortBindings) {
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
            self.boundAddresses.removeAll()
            self.onPortsChanged?([])
        }
    }

    // MARK: - Queue-confined

    private func syncLocked(desired: DockerAPIClient.PortBindings,
                            listeners: inout [UInt16: NWListener], isUDP: Bool) {
        let proto = isUDP ? "udp" : "tcp"
        for (port, listener) in listeners where desired[port] != boundAddresses["\(proto)/\(port)"] {
            listener.cancel()
            listeners.removeValue(forKey: port)
            boundAddresses.removeValue(forKey: "\(proto)/\(port)")
        }
        for (port, address) in desired where listeners[port] == nil {
            if let listener = startListener(on: port, address: address, isUDP: isUDP) {
                listeners[port] = listener
                boundAddresses["\(proto)/\(port)"] = address
            }
        }
    }

    private func startListener(on port: UInt16, address: String, isUDP: Bool) -> NWListener? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters: NWParameters = isUDP ? .udp : .tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(address), port: nwPort)
        guard let listener = try? NWListener(using: parameters) else {
            NSLog("dockz: cannot listen on %@:%d/%@ (in use?)", address, Int(port), isUDP ? "udp" : "tcp")
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
