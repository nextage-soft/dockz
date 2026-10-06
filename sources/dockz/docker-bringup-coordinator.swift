import Foundation

/// After the VM reaches .running, this coordinator brings up the docker side:
/// unix-socket bridge, readiness polling, docker context, guest IP resolution,
/// event stream and port-forward reconciliation.
@MainActor
final class DockerBringupCoordinator {
    private let vm: VMController
    private let paths: DockzPaths
    private var bridge: DockerSocketBridge?
    private var debugShellBridge: DockerSocketBridge?
    private var api: DockerAPIClient?
    private let forwarder = PortForwarder()
    private var pingTimer: Timer?
    private var reconcileTimer: Timer?
    private var reconcileDebounce: Timer?
    private var stopped = false

    private(set) var dockerReady = false
    private(set) var guestIP: String?
    var apiClient: DockerAPIClient? { dockerReady ? api : nil }
    private(set) var forwardedPorts: [UInt16] = []
    /// Set when part of the bring-up failed in a way the user must see.
    private(set) var setupError: String?
    var onUpdate: (() -> Void)?

    init(vm: VMController, paths: DockzPaths) {
        self.vm = vm
        self.paths = paths
    }

    func start() {
        let connect = vm.vsockConnector()
        api = DockerAPIClient(endpoint: .vsock(connect))

        // Without docker.sock the docker CLI cannot reach the engine even
        // though the dashboard (over vsock) still works, so say so instead of
        // only logging it.
        let bridge = DockerSocketBridge(socketPath: paths.dockerSocket.path, connectVsock: connect)
        do {
            try bridge.start()
            self.bridge = bridge
        } catch {
            setupError = "The docker CLI can't reach DockZ: \(error.localizedDescription)"
            HostLog.write("docker.sock bridge failed: \(error.localizedDescription)")
        }

        // Root shell into the guest for debugging: nc -U <data folder>/debug-shell.sock
        let shellBridge = DockerSocketBridge(socketPath: paths.debugShellSocket.path, vsockPort: 2378, connectVsock: connect)
        do {
            try shellBridge.start()
            debugShellBridge = shellBridge
        } catch {
            HostLog.write("debug-shell.sock bridge failed: \(error.localizedDescription)")
        }

        forwarder.onPortsChanged = { [weak self] ports in
            DispatchQueue.main.async {
                self?.forwardedPorts = ports
                self?.onUpdate?()
            }
        }

        pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollDockerReady() }
        }
        pollDockerReady()
    }

    func stop() {
        stopped = true
        pingTimer?.invalidate()
        reconcileTimer?.invalidate()
        reconcileDebounce?.invalidate()
        pingTimer = nil
        reconcileTimer = nil
        reconcileDebounce = nil
        bridge?.stop()
        bridge = nil
        debugShellBridge?.stop()
        debugShellBridge = nil
        forwarder.stopAll()
    }

    // MARK: - Readiness

    private func pollDockerReady() {
        guard !stopped, !dockerReady else { return }
        api?.ping { [weak self] ok in
            guard ok else { return }
            DispatchQueue.main.async { self?.becameReady() }
        }
    }

    private func becameReady() {
        guard !dockerReady, !stopped else { return }
        dockerReady = true
        pingTimer?.invalidate()
        pingTimer = nil
        DockerContextInstaller.ensureContext(socketPath: paths.dockerSocket.path)
        resolveGuestIP(attempt: 0)
        startEventStream()
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcilePorts() }
        }
        reconcilePorts()
        onUpdate?()
    }

    private func resolveGuestIP(attempt: Int) {
        GuestIPResolver.fetch(connect: vm.vsockConnector()) { [weak self] ip in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                if let ip {
                    self.guestIP = ip
                    self.forwarder.setGuestIP(ip)
                    self.onUpdate?()
                } else if attempt < 15 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.resolveGuestIP(attempt: attempt + 1)
                    }
                }
            }
        }
    }

    // MARK: - Events & ports

    /// Posted on the main queue for every Docker event of the local engine,
    /// so views refresh on change instead of polling.
    static let engineActivity = Notification.Name("DockerBringupCoordinator.engineActivity")

    private func startEventStream() {
        guard !stopped else { return }
        api?.streamEvents(
            onActivity: { [weak self] in
                DispatchQueue.main.async {
                    self?.scheduleReconcile()
                    NotificationCenter.default.post(name: DockerBringupCoordinator.engineActivity, object: nil)
                }
            },
            onClose: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.startEventStream() }
                }
            }
        )
    }

    private func scheduleReconcile() {
        reconcileDebounce?.invalidate()
        reconcileDebounce = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reconcilePorts() }
        }
    }

    private func reconcilePorts() {
        guard dockerReady, !stopped else { return }
        api?.listPublishedPorts { [weak self] tcp, udp in
            self?.forwarder.sync(tcp: tcp, udp: udp)
        }
    }
}
