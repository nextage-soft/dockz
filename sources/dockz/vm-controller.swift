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
        queue.async {
            guard let vm = self.virtualMachine, vm.state == .running else {
                self.forceStop(completion: completion)
                return
            }
            self.stopCompletion = completion
            self.state = .stopping
            if let device = vm.socketDevices.first as? VZVirtioSocketDevice {
                device.connect(toPort: Self.powerOffVsockPort) { result in
                    if case .success(let connection) = result { connection.close() }
                }
            }
            try? vm.requestStop()
            self.queue.asyncAfter(deadline: .now() + 15) {
                if self.virtualMachine != nil { self.forceStop(completion: nil) }
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
        vm.stop { _ in
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
        self.virtualMachine = nil
        state = .stopped
        fireStopCompletion()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        self.virtualMachine = nil
        state = .failed(error.localizedDescription)
        fireStopCompletion()
    }
}
