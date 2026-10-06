import Foundation

// Keeps the Docker VM usable when its guest kernel fails. Observed
// 2026-10-02: a kernel oops in the guest's vsock path corrupted memory, ext4
// then deadlocked (containerd-shim stuck 2451 s), dockerd stopped answering
// and every container "disappeared" from the dashboard for hours. Three
// layers, from inside out:
//  1. GuestKernelGuard — the guest panics and reboots itself on an oops or a
//     soft lockup instead of hanging.
//  2. VMRestartPolicy — an unexpected VM stop (that reboot, or a host-side
//     Virtualization error) restarts the VM, with a crash-loop limit.
//  3. EngineHealthTracker / EngineWatchdog — an engine that stops answering
//     while the VM looks alive gets the VM restarted.
// ConsoleLogRotation keeps the evidence of earlier boots.

/// Guest kernel settings applied after every boot over the vsock shell (no
/// image rebuild needed). A guest reboot ends the VZ machine, which layer 2
/// then restarts.
enum GuestKernelGuard {
    /// Seconds between a panic and the reboot — time for the console to flush.
    static let rebootDelaySeconds = 10

    static var script: String {
        """
        sysctl -w kernel.panic_on_oops=1 kernel.softlockup_panic=1 kernel.panic=\(rebootDelaySeconds) >/dev/null \
          && echo "DOCKZ-KGUARD $(cat /proc/sys/kernel/panic_on_oops)$(cat /proc/sys/kernel/softlockup_panic)"
        """
    }

    static func apply(connect: @escaping DockerAPIClient.VsockConnect, completion: @escaping (Bool) -> Void) {
        GuestShellRunner.run(script: script, connect: connect) { output in
            let applied = output?.contains("DOCKZ-KGUARD 11") ?? false
            HostLog.write(applied ? "guest kernel guard on (panic on oops / soft lockup)"
                                  : "guest kernel guard NOT applied")
            completion(applied)
        }
    }
}

/// Decides whether an unexpected stop may restart the VM: at most
/// `maxRestarts` within `window`, so a VM that dies right after booting
/// doesn't restart forever.
struct VMRestartPolicy {
    var maxRestarts = 3
    var window: TimeInterval = 600
    private(set) var restarts: [TimeInterval] = []

    /// `now` is a monotonic clock reading (seconds).
    mutating func allowRestart(at now: TimeInterval) -> Bool {
        restarts.removeAll { now - $0 > window }
        guard restarts.count < maxRestarts else { return false }
        restarts.append(now)
        return true
    }

    enum StopKind: Equatable {
        /// DockZ asked the VM to stop.
        case requested
        /// The VM never reached .running: a configuration or resource problem
        /// (e.g. its disk is held by another process). Restarting cannot fix
        /// it and only hides the reason, so it is reported instead.
        case failedToStart
        /// The VM was running and stopped on its own: kernel guard reboot,
        /// Virtualization error. Restart it (within the crash-loop limit).
        case crashed
    }

    static func classify(stopWasRequested: Bool, reachedRunning: Bool) -> StopKind {
        if stopWasRequested { return .requested }
        return reachedRunning ? .crashed : .failedToStart
    }
}

/// Judges /_ping results. Unresponsive = several failures in a row AND no
/// success for `deadline` seconds of awake time. ProcessInfo.systemUptime
/// stops while the Mac sleeps, so waking up never looks like a long outage.
struct EngineHealthTracker {
    var failuresNeeded = 4
    var deadline: TimeInterval = 60
    private(set) var consecutiveFailures = 0
    private(set) var lastSuccess: TimeInterval

    init(now: TimeInterval) {
        lastSuccess = now
    }

    /// Returns true when the engine should be considered dead.
    mutating func record(success: Bool, at now: TimeInterval) -> Bool {
        if success {
            consecutiveFailures = 0
            lastSuccess = now
            return false
        }
        consecutiveFailures += 1
        return consecutiveFailures >= failuresNeeded && now - lastSuccess >= deadline
    }
}

/// Pings the local engine on a timer while it is supposed to be up.
@MainActor
final class EngineWatchdog {
    static let interval: TimeInterval = 15

    private var timer: Timer?
    private var tracker = EngineHealthTracker(now: ProcessInfo.processInfo.systemUptime)
    private var inFlight = false
    private var fired = false

    /// `onUnresponsive` fires once per start.
    func start(api: @escaping () -> DockerAPIClient?, onUnresponsive: @escaping () -> Void) {
        stop()
        tracker = EngineHealthTracker(now: ProcessInfo.processInfo.systemUptime)
        fired = false
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.inFlight, !self.fired, let client = api() else { return }
                self.inFlight = true
                client.ping { ok in
                    Task { @MainActor in
                        self.inFlight = false
                        guard self.timer != nil, !self.fired else { return }
                        if self.tracker.record(success: ok, at: ProcessInfo.processInfo.systemUptime) {
                            self.fired = true
                            onUnresponsive()
                        }
                    }
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        inFlight = false
    }
}

/// console.log is rewritten every boot, which erased the oops that explained
/// a hang by the time anyone looked. Keep the previous few boots alongside.
enum ConsoleLogRotation {
    static let keep = 5

    /// console.log → console.1.log → … → console.(keep-1).log; oldest dropped.
    static func rotate(_ log: URL, keep: Int = keep, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: log.path) else { return }
        let directory = log.deletingLastPathComponent()
        let stem = log.deletingPathExtension().lastPathComponent
        func numbered(_ index: Int) -> URL { directory.appendingPathComponent("\(stem).\(index).log") }
        try? fileManager.removeItem(at: numbered(keep - 1))
        for index in stride(from: keep - 2, through: 1, by: -1) where fileManager.fileExists(atPath: numbered(index).path) {
            try? fileManager.moveItem(at: numbered(index), to: numbered(index + 1))
        }
        try? fileManager.moveItem(at: log, to: numbered(1))
    }
}
