import Foundation

/// Sampling engine behind the Monitor tab. Runs only while the tab is open
/// (the view calls start/stop): VM vitals every tick, per-container stats
/// from one long-lived Docker stats stream per running container (read at
/// each tick — no new connection per sample), and the /system/df breakdown
/// every tenth tick (docker walks the filesystem for it) — but on every tick
/// until the first one succeeds, so the tab never sits on "Measuring…" for
/// ten ticks because the first request went out before the engine answered.
@MainActor
final class MonitorStore: ObservableObject {
    static let historyLength = 100
    nonisolated private static let breakdownEveryTicks = 10

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
    /// Running containers at the last tick: lets the view tell "stats still
    /// arriving" apart from "nothing running" while `rows` is empty.
    @Published private(set) var runningCount = 0
    @Published private(set) var breakdown: MonitorParse.DiskBreakdown?
    @Published private(set) var hostAllocatedBytes: UInt64 = 0
    /// The disk limit from Settings — what "used" is measured against.
    @Published private(set) var diskLimitBytes: UInt64 = 0
    /// Free space on the Mac volume holding the data folder.
    @Published private(set) var hostFreeBytes: UInt64?
    @Published private(set) var engineInfoLabel = ""

    private var timer: Timer?
    private var previousGuest: MonitorParse.GuestSnapshot?
    private var previousSamples: [String: MonitorParse.ContainerSample] = [:]
    private var previousSampleAt: Date?
    private var tick = 0
    private var breakdownInFlight = false
    private let statsStreams = ContainerStatsStreams()

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
        statsStreams.stopAll()
        // Rates are deltas; stale baselines would spike on the next open.
        previousGuest = nil
        previousSamples = [:]
        previousSampleAt = nil
    }

    /// Clears everything measured on the previous engine (rows, history,
    /// delta baselines) while keeping the timer, so the new one starts clean.
    func resetForEnvironmentChange() {
        statsStreams.stopAll()
        vm = nil
        vmCPUPercent = 0
        cpuHistory = []
        memHistory = []
        rows = []
        runningCount = 0
        breakdown = nil
        previousGuest = nil
        previousSamples = [:]
        previousSampleAt = nil
        tick = 0
    }

    private func sample() {
        sampleVM()
        sampleContainers()
        if Self.shouldSampleBreakdown(tick: tick, haveBreakdown: breakdown != nil, inFlight: breakdownInFlight) {
            sampleBreakdown()
        }
        let paths = DockzPaths()
        hostAllocatedBytes = DiskUsage.allocatedBytes(at: paths.diskImage) ?? 0
        diskLimitBytes = DiskLimit.bytes(forGB: DockzSettings.load(from: paths).diskLimitGB)
        hostFreeBytes = DiskUsage.volumeAvailableBytes(at: paths.baseDirectory)
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
                    ? Double(snapshot.memUsedKiB) / Double(snapshot.memTotalKiB)
                    : 0
                self.push(&self.memHistory, usedFraction)
            }
        }
    }

    private func sampleContainers() {
        guard let client = api() else {
            statsStreams.stopAll()
            rows = []
            engineInfoLabel = ""
            return
        }
        let running = runningContainers().filter(\.isRunning)
        runningCount = running.count
        engineInfoLabel = "\(running.count) container\(running.count == 1 ? "" : "s") running"
        statsStreams.sync(running: Set(running.map(\.id)), client: client)

        let now = Date()
        let interval = previousSampleAt.map { now.timeIntervalSince($0) } ?? tickInterval
        previousSampleAt = now
        var updated: [String: MonitorParse.ContainerSample] = [:]
        var newRows: [ContainerRow] = []
        for container in running {
            guard let dict = statsStreams.latestSample(for: container.id),
                  let sample = MonitorParse.containerSample(from: dict) else { continue }
            let previous = previousSamples[container.id]
            newRows.append(ContainerRow(
                id: container.id,
                name: container.name,
                cpuPercent: sample.cpuPercent,
                memUsedBytes: sample.memUsedBytes,
                memLimitBytes: sample.memLimitBytes,
                netRxPerSecond: previous.map { MonitorParse.rate($0.netRxBytes, sample.netRxBytes, seconds: interval) } ?? 0,
                netTxPerSecond: previous.map { MonitorParse.rate($0.netTxBytes, sample.netTxBytes, seconds: interval) } ?? 0,
                blockReadPerSecond: previous.map { MonitorParse.rate($0.blockReadBytes, sample.blockReadBytes, seconds: interval) } ?? 0,
                blockWritePerSecond: previous.map { MonitorParse.rate($0.blockWriteBytes, sample.blockWriteBytes, seconds: interval) } ?? 0
            ))
            updated[container.id] = sample
        }
        previousSamples = updated
        rows = newRows.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    /// Until a breakdown exists, ask on every tick (one request at a time);
    /// afterwards, every `breakdownEveryTicks` ticks.
    nonisolated static func shouldSampleBreakdown(tick: Int, haveBreakdown: Bool, inFlight: Bool) -> Bool {
        guard !inFlight else { return false }
        return !haveBreakdown || tick % breakdownEveryTicks == 0
    }

    private func sampleBreakdown() {
        guard let client = api() else { return }
        breakdownInFlight = true
        client.systemDiskUsage { [weak self] dict in
            DispatchQueue.main.async {
                guard let self else { return }
                self.breakdownInFlight = false
                if let dict { self.breakdown = MonitorParse.diskBreakdown(from: dict) }
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
