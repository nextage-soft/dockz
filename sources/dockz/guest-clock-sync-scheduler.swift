import AppKit

/// Decides when GuestClockSync runs, for every running VM at once (the Docker
/// VM and Alpine machines alike): on wake, when the Mac's clock or time zone
/// changes, and on a one-minute timer. The engine-up sync is requested by the
/// caller. Corrections are logged, so a clock that keeps drifting shows up in
/// host.log instead of in someone's database timestamps.
@MainActor
final class GuestClockSyncScheduler {
    struct Target {
        let name: String
        let connect: DockerAPIClient.VsockConnect
    }

    /// Running VMs whose guest has the vsock shell.
    private let targets: () -> [Target]
    /// Called on a time-zone change, so the zone can be pushed alongside.
    private let onZoneChange: () -> Void
    private var workspaceObservers: [NSObjectProtocol] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    /// Right after wake the VM may not answer for a moment; retry this often.
    static let wakeRetries = 3
    static let wakeRetryDelay: TimeInterval = 5

    init(targets: @escaping () -> [Target], onZoneChange: @escaping () -> Void) {
        self.targets = targets
        self.onZoneChange = onZoneChange
    }

    func start() {
        guard timer == nil else { return }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAll(.wake, retries: Self.wakeRetries) }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAll(.clockChanged) }
        })
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // TimeZone.current is cached per process until reset.
                NSTimeZone.resetSystemTimeZone()
                self?.onZoneChange()
                self?.syncAll(.zoneChanged)
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: GuestClockSync.periodicInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAll(.periodic) }
        }
    }

    func syncAll(_ reason: GuestClockSync.Reason, retries: Int = 0) {
        for target in targets() {
            sync(target, reason: reason, retriesLeft: retries)
        }
    }

    private func sync(_ target: Target, reason: GuestClockSync.Reason, retriesLeft: Int) {
        GuestClockSync.sync(connect: target.connect) { outcome in
            DispatchQueue.main.async { [weak self] in
                switch outcome {
                case .corrected(let offset)?:
                    HostLog.write("clock: \(target.name) was \(GuestClockSync.describe(offset)) — set to the Mac's time (\(reason.rawValue))")
                case .inSync?:
                    break
                case nil where retriesLeft > 0:
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeRetryDelay) {
                        guard let self, let again = self.targets().first(where: { $0.name == target.name }) else { return }
                        self.sync(again, reason: reason, retriesLeft: retriesLeft - 1)
                    }
                case nil:
                    // The periodic check races VM stops; only a missed event sync is news.
                    if reason != .periodic {
                        HostLog.write("clock: could not reach \(target.name) to check its time (\(reason.rawValue))")
                    }
                }
            }
        }
    }
}
