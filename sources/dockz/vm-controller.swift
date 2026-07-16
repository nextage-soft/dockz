import Foundation
import Virtualization

enum VMState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

/// Owns the VZVirtualMachine and the serial dispatch queue it is confined to.
/// All Virtualization.framework calls happen on `queue`.
final class VMController: NSObject, VZVirtualMachineDelegate {
    /// Guest vsock port that powers the VM off when connected to.
    static let powerOffVsockPort: UInt32 = 2377

    private let queue = DispatchQueue(label: "com.nextagesoft.dockz.vm")
    private var virtualMachine: VZVirtualMachine?
    private let paths: DockzPaths
    private let settings: DockzSettings
    private var stopCompletion: (() -> Void)?

    /// Called on the main queue whenever the state changes.
    var onStateChange: ((VMState) -> Void)?

    private(set) var state: VMState = .stopped {
        didSet {
            let newState = state
            HostLog.write("vm state → \(newState)")
            DispatchQueue.main.async { self.onStateChange?(newState) }
        }
    }

    init(paths: DockzPaths, settings: DockzSettings) {
        self.paths = paths
        self.settings = settings
    }

    func start() {
        queue.async {
            guard self.virtualMachine == nil else { return }
            self.state = .starting
            do {
                let config = try VMConfigBuilder.build(paths: self.paths, settings: self.settings)
                let vm = VZVirtualMachine(configuration: config, queue: self.queue)
                vm.delegate = self
                self.virtualMachine = vm
                vm.start { result in
                    if case .failure(let error) = result {
                        self.virtualMachine = nil
                        self.state = .failed(error.localizedDescription)
                    } else {
                        self.state = .running
                    }
                }
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Asks the guest to power off (vsock agent + platform stop request) and
    /// force-stops if it does not comply within 15 seconds.
    func stop(completion: (() -> Void)? = nil) {
        HostLog.write("stop requested")
        queue.async {
            guard let vm = self.virtualMachine, vm.state == .running else {
                HostLog.write("stop: VM not running (vzState: \(self.virtualMachine?.state.rawValue ?? -1)) — force stopping")
                self.forceStop(completion: completion)
                return
            }
            self.stopCompletion = completion
            self.state = .stopping
            // Graceful path: connecting to the guest's poweroff port makes its
            // socat agent run /sbin/poweroff; guestDidStop then fires. Hold the
            // connection open for a beat — closing it the instant the handshake
            // completes can tear down the guest side before socat has forked
            // and exec'd the poweroff helper. (No requestStop here: a Linux
            // guest has no channel for it, so it only muddies the water.)
            if let device = vm.socketDevices.first as? VZVirtioSocketDevice {
                device.connect(toPort: Self.powerOffVsockPort) { result in
                    switch result {
                    case .success(let connection):
                        HostLog.write("poweroff: vsock \(Self.powerOffVsockPort) connected, awaiting guest shutdown")
                        self.queue.asyncAfter(deadline: .now() + 2) { connection.close() }
                    case .failure(let error):
                        HostLog.write("poweroff: vsock connect failed (\(error)) — will force stop")
                    }
                }
            }
            self.queue.asyncAfter(deadline: .now() + 15) {
                if self.virtualMachine != nil {
                    HostLog.write("graceful shutdown timed out after 15s — force stopping")
                    self.forceStop(completion: nil)
                }
            }
        }
    }

    private func forceStop(completion: (() -> Void)?) {
        if let completion {
            let previous = stopCompletion
            stopCompletion = { previous?(); completion() }
        }
        guard let vm = virtualMachine else {
            state = .stopped
            fireStopCompletion()
            return
        }
        vm.stop { error in
            if let error { HostLog.write("force stop error: \(error)") }
            self.virtualMachine = nil
            self.state = .stopped
            self.fireStopCompletion()
        }
    }

    private func fireStopCompletion() {
        let completion = stopCompletion
        stopCompletion = nil
        if let completion { DispatchQueue.main.async(execute: completion) }
    }

    // MARK: - vsock

    /// Connects to a vsock port inside the guest. The completion handler may
    /// be invoked on the VM queue.
    func connectVsock(port: UInt32, completion: @escaping (Result<VZVirtioSocketConnection, Error>) -> Void) {
        queue.async {
            guard let vm = self.virtualMachine, vm.state == .running,
                  let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
                completion(.failure(DockzError.vmNotRunning))
                return
            }
            device.connect(toPort: port, completionHandler: completion)
        }
    }

    func vsockConnector() -> (UInt32, @escaping (Result<VZVirtioSocketConnection, Error>) -> Void) -> Void {
        return { [weak self] port, completion in
            guard let self else {
                completion(.failure(DockzError.vmNotRunning))
                return
            }
            self.connectVsock(port: port, completion: completion)
        }
    }

    // MARK: - VZVirtualMachineDelegate (called on our queue)

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        HostLog.write("guestDidStop (guest powered itself off)")
        self.virtualMachine = nil
        state = .stopped
        fireStopCompletion()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        HostLog.write("didStopWithError: \(error)")
        self.virtualMachine = nil
        state = .failed(error.localizedDescription)
        fireStopCompletion()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine,
                        networkDevice: VZNetworkDevice,
                        attachmentWasDisconnectedWithError error: Error) {
        HostLog.write("network attachment disconnected: \(error)")
    }
}
