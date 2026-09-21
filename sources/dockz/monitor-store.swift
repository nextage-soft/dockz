import Foundation

/// Sampling engine behind the Monitor tab. Polls only while the tab is open
/// (the view calls start/stop): VM vitals + per-container stats every tick,
/// the /system/df breakdown every tenth tick (docker walks the filesystem for
/// it, so it is much heavier than the rest).
@MainActor
final class MonitorStore: ObservableObject {
    static let historyLength = 100
    private static let breakdownEveryTicks = 10

    /// Seconds between samples; user-selectable (1/3/5). At the 5 s default the
    /// 100-point history spans ≈ 8 minutes.
    @Published var tickInterval: TimeInterval = 5 {
        didSet {
            guard timer != nil, tickInterval != oldValue else { return }
            restartTimer()
        }
    }

    struct ContainerRow: Identifiable {
        let id: String
        var name: String
        var cpuPercent: Double
        var memUsedBytes: UInt64
        var memLimitBytes: UInt64
        var netRxPerSecond: Double
        var netTxPerSecond: Double
        var blockReadPerSecond: Double
        var blockWritePerSecond: Double
    }

    @Published private(set) var vm: MonitorParse.GuestSnapshot?
    @Published private(set) var vmCPUPercent: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []   // used fraction 0…1
    @Published private(set) var rows: [ContainerRow] = []
    @Published private(set) var breakdown: MonitorParse.DiskBreakdown?
    @Published private(set) var hostAllocatedBytes: UInt64 = 0
    @Published private(set) var engineInfoLabel = ""

    private var timer: Timer?
    private var previousGuest: MonitorParse.GuestSnapshot?
    private var previousSamples: [String: MonitorParse.ContainerSample] = [:]
    private var previousSampleAt: Date?
    private var tick = 0

    private var api: () -> DockerAPIClient? = { nil }
    private var shell: () -> DockerAPIClient.VsockConnect? = { nil }
    private var runningContainers: () -> [ContainerSummary] = { [] }

    var isRunning: Bool { timer != nil }

    func start(api: @escaping () -> DockerAPIClient?,
               shell: @escaping () -> DockerAPIClient.VsockConnect?,
               containers: @escaping () -> [ContainerSummary]) {
        self.api = api
        self.shell = shell
        self.runningContainers = containers
        guard timer == nil else { return }
        tick = 0
        sample()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // Rates are deltas; stale baselines would spike on the next open.
        previousGuest = nil
        previousSamples = [:]
        previousSampleAt = nil
    }

    private func sample() {
        sampleVM()
        sampleContainers()
        if tick % Self.breakdownEveryTicks == 0 { sampleBreakdown() }
        hostAllocatedBytes = DiskUsage.allocatedBytes(at: DockzPaths().diskImage) ?? 0
        tick += 1
    }

    private func sampleVM() {
        guard let connect = shell() else {
            vm = nil
            return
        }
        GuestShellRunner.run(script: MonitorParse.guestScript, connect: connect) { [weak self] output in
            DispatchQueue.main.async {
                guard let self, let output,
                      let snapshot = MonitorParse.guestSnapshot(from: output) else { return }
                if let previous = self.previousGuest {
                    self.vmCPUPercent = MonitorParse.cpuPercent(previous: previous, current: snapshot)
                }
                self.previousGuest = snapshot
                self.vm = snapshot
                self.push(&self.cpuHistory, self.vmCPUPercent / 100)
                let usedFraction = snapshot.memTotalKiB > 0
                    ? Double(snapshot.memTotalKiB - snapshot.memAvailableKiB) / Double(snapshot.memTotalKiB)
                    : 0
                self.push(&self.memHistory, usedFraction)
            }
        }
    }

    private func sampleContainers() {
        guard let client = api() else {
            rows = []
            engineInfoLabel = ""
            return
        }
        let running = runningContainers().filter(\.isRunning)
        engineInfoLabel = "\(running.count) container\(running.count == 1 ? "" : "s") running"
        let now = Date()
        let interval = previousSampleAt.map { now.timeIntervalSince($0) } ?? tickInterval
        previousSampleAt = now

        var updated: [String: MonitorParse.ContainerSample] = [:]
        let group = DispatchGroup()
        var newRows: [ContainerRow] = []
        let lock = NSLock()
        for container in running {
            group.enter()
            client.containerStatsRaw(id: container.id) { [weak self] dict in
                defer { group.leave() }
                guard let self, let dict,
                      let sample = MonitorParse.containerSample(from: dict) else { return }
                let previous = self.previousSamples[container.id]
                let row = ContainerRow(
                    id: container.id,
                    name: container.name,
                    cpuPercent: sample.cpuPercent,
                    memUsedBytes: sample.memUsedBytes,
                    memLimitBytes: sample.memLimitBytes,
                    netRxPerSecond: previous.map { MonitorParse.rate($0.netRxBytes, sample.netRxBytes, seconds: interval) } ?? 0,
                    netTxPerSecond: previous.map { MonitorParse.rate($0.netTxBytes, sample.netTxBytes, seconds: interval) } ?? 0,
                    blockReadPerSecond: previous.map { MonitorParse.rate($0.blockReadBytes, sample.blockReadBytes, seconds: interval) } ?? 0,
                    blockWritePerSecond: previous.map { MonitorParse.rate($0.blockWriteBytes, sample.blockWriteBytes, seconds: interval) } ?? 0
                )
                lock.lock()
                newRows.append(row)
                updated[container.id] = sample
                lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.previousSamples = updated
            self.rows = newRows.sorted { $0.cpuPercent > $1.cpuPercent }
        }
    }

    private func sampleBreakdown() {
        api()?.systemDiskUsage { [weak self] dict in
            DispatchQueue.main.async {
                guard let self, let dict else { return }
                self.breakdown = MonitorParse.diskBreakdown(from: dict)
            }
        }
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }
}
