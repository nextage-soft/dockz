import Foundation
import Network

/// Relays bytes between two NWConnections (host client <-> guest port).
/// Keeps itself alive in a registry until both directions finish.
final class TCPRelay {
    private static let registryQueue = DispatchQueue(label: "com.nextagesoft.dockz.relay-registry")
    private static var active: [UUID: TCPRelay] = [:]

    private let id = UUID()
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue: DispatchQueue
    private var finishedDirections = 0
    private var closed = false

    init(inbound: NWConnection, outbound: NWConnection, queue: DispatchQueue) {
        self.inbound = inbound
        self.outbound = outbound
        self.queue = queue
    }

    func start() {
        Self.registryQueue.sync { Self.active[id] = self }
        inbound.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.closeBoth() }
        }
        outbound.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.closeBoth() }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil {
                        self.closeBoth()
                    } else if isComplete {
                        self.halfClose(destination)
                    } else {
                        self.pump(from: source, to: destination)
                    }
                })
            } else if isComplete {
                self.halfClose(destination)
            } else if error != nil {
                self.closeBoth()
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }

    private func halfClose(_ destination: NWConnection) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        finishedDirections += 1
        if finishedDirections >= 2 { closeBoth() }
    }

    private func closeBoth() {
        guard !closed else { return }
        closed = true
        inbound.cancel()
        outbound.cancel()
        Self.registryQueue.async { Self.active.removeValue(forKey: self.id) }
    }
}
