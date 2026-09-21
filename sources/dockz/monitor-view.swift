import SwiftUI

/// Monitor tab: live VM vitals with sparklines, a sortable per-container
/// resource table, and the /system/df storage breakdown. Sampling runs only
/// while this view is on screen.
struct MonitorView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var monitor: MonitorStore
    @State private var sort: SortKey = .cpu
    @State private var showCleanup = false
    /// Rows shown in the per-container table; 0 means all.
    @State private var rowLimit = 5

    enum SortKey: String, CaseIterable {
        case cpu = "CPU"
        case memory = "RAM"
        case network = "Net"
        case disk = "Disk"
        case name = "Name"
    }

    private static let rowLimitChoices: [(label: String, value: Int)] = [
        ("5", 5), ("10", 10), ("20", 20), ("All", 0),
    ]
    private static let refreshChoices: [TimeInterval] = [1, 3, 5]

    init(store: DashboardStore) {
        self.store = store
        self.monitor = store.monitor
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()
                    Text("Refresh").font(.caption).foregroundStyle(.secondary)
                    Picker("Refresh", selection: $monitor.tickInterval) {
                        ForEach(Self.refreshChoices, id: \.self) { interval in
                            Text("\(Int(interval))s").tag(interval)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 70)
                }
                vitalsGrid
                containerTable
                breakdownCard
            }
            .padding(16)
        }
        .onAppear {
            monitor.start(api: store.apiProvider, shell: store.shellProvider,
                          containers: { [weak store] in store?.containers ?? [] })
        }
        .onDisappear { monitor.stop() }
        .sheet(isPresented: $showCleanup) { CleanupSheetView(store: store) }
    }

    // MARK: - Vitals

    private var vitalsGrid: some View {
        // Four equal columns — adaptive sizing let the cards drift apart.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            metricCard("VM CPU", value: String(format: "%.0f%%", monitor.vmCPUPercent)) {
                Sparkline(values: monitor.cpuHistory).stroke(Color.blue, lineWidth: 1.5)
            } footer: {
                monitor.vm.map { String(format: "load %.2f", $0.load1) } ?? "—"
            }
            metricCard("VM memory", value: memorySummary) {
                Sparkline(values: monitor.memHistory).stroke(Color.green, lineWidth: 1.5)
            } footer: {
                monitor.vm.map { "cache \(Self.bytes($0.cachedKiB * 1024))" } ?? "—"
            }
            metricCard("Disk", value: diskSummary) {
                usageBar(fraction: diskFraction, color: .purple)
            } footer: {
                "on your Mac: \(Self.bytes(monitor.hostAllocatedBytes))"
            }
            metricCard("Engine", value: monitor.engineInfoLabel.isEmpty ? "—" : monitor.engineInfoLabel) {
                // Same-size placeholder: EmptyView takes no space and made this
                // card shorter than its siblings.
                Color.clear
            } footer: {
                monitor.vm.map { "uptime \(Self.duration($0.uptimeSeconds))" } ?? "engine offline"
            }
        }
    }

    private func metricCard(_ title: String, value: String,
                            @ViewBuilder chart: () -> some View,
                            footer: () -> String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            chart().frame(height: 22).frame(maxWidth: .infinity)
            Text(footer()).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(10)
        // One fixed frame for every card, whatever it contains — uneven
        // heights across sibling cards read as broken.
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var memorySummary: String {
        guard let vm = monitor.vm, vm.memTotalKiB > 0 else { return "—" }
        let used = (vm.memTotalKiB - vm.memAvailableKiB) * 1024
        return "\(Self.bytes(used)) / \(Self.bytes(vm.memTotalKiB * 1024))"
    }

    private var diskSummary: String {
        guard let vm = monitor.vm, vm.diskSizeKiB > 0 else { return "—" }
        return "\(Self.bytes(vm.diskUsedKiB * 1024)) / \(Self.bytes(vm.diskSizeKiB * 1024))"
    }

    private var diskFraction: Double {
        guard let vm = monitor.vm, vm.diskSizeKiB > 0 else { return 0 }
        return Double(vm.diskUsedKiB) / Double(vm.diskSizeKiB)
    }

    private func usageBar(fraction: Double, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(3, proxy.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Container table

    private var sortedRows: [MonitorStore.ContainerRow] {
        switch sort {
        case .cpu: return monitor.rows.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: return monitor.rows.sorted { $0.memUsedBytes > $1.memUsedBytes }
        case .network: return monitor.rows.sorted {
            $0.netRxPerSecond + $0.netTxPerSecond > $1.netRxPerSecond + $1.netTxPerSecond
        }
        case .disk: return monitor.rows.sorted {
            $0.blockReadPerSecond + $0.blockWritePerSecond > $1.blockReadPerSecond + $1.blockWritePerSecond
        }
        case .name: return monitor.rows.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        }
    }

    /// Rows actually rendered after the row-limit picker.
    private var visibleRows: [MonitorStore.ContainerRow] {
        rowLimit > 0 ? Array(sortedRows.prefix(rowLimit)) : sortedRows
    }

    private var containerTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Per container").font(.callout.weight(.semibold))
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Picker("Rows", selection: $rowLimit) {
                    ForEach(Self.rowLimitChoices, id: \.value) { choice in
                        Text(choice.label).tag(choice.value)
                    }
                }
                .frame(maxWidth: 76)
                .help("How many containers to list")
            }
            if sortedRows.isEmpty {
                Text("No running containers.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Name"); Text("CPU"); Text("RAM"); Text("Net ↓/↑"); Text("Disk R/W")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(visibleRows) { row in
                        GridRow {
                            Text(row.name).lineLimit(1)
                            HStack(spacing: 6) {
                                usageBar(fraction: row.cpuPercent / 100, color: .blue)
                                    .frame(width: 48)
                                Text(String(format: "%.0f%%", row.cpuPercent))
                                    .font(.callout.monospacedDigit())
                            }
                            Text(memoryCell(row)).font(.callout.monospacedDigit())
                            Text("\(Self.rate(row.netRxPerSecond)) / \(Self.rate(row.netTxPerSecond))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text("\(Self.rate(row.blockReadPerSecond)) / \(Self.rate(row.blockWritePerSecond))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if rowLimit > 0 && sortedRows.count > rowLimit {
                    Text("Showing \(rowLimit) of \(sortedRows.count) — pick a larger limit to see the rest.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func memoryCell(_ row: MonitorStore.ContainerRow) -> String {
        // A container without its own limit reports the VM total — not useful.
        let hasLimit = row.memLimitBytes > 0 && monitor.vm.map {
            row.memLimitBytes < $0.memTotalKiB * 1024
        } ?? true
        return hasLimit
            ? "\(Self.bytes(row.memUsedBytes)) / \(Self.bytes(row.memLimitBytes))"
            : Self.bytes(row.memUsedBytes)
    }

    // MARK: - Storage breakdown

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Storage by type").font(.callout.weight(.semibold))
                Spacer()
                Button {
                    showCleanup = true
                } label: {
                    Label("Clean Up…", systemImage: "paintbrush")
                }
                .controlSize(.small)
                .disabled(!store.engineReady)
            }
            if let breakdown = monitor.breakdown, breakdown.totalBytes > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 1) {
                        segment(breakdown.imagesBytes, of: breakdown.totalBytes, width: proxy.size.width, color: .blue)
                        segment(breakdown.containersBytes, of: breakdown.totalBytes, width: proxy.size.width, color: .green)
                        segment(breakdown.volumesBytes, of: breakdown.totalBytes, width: proxy.size.width, color: .purple)
                        segment(breakdown.buildCacheBytes, of: breakdown.totalBytes, width: proxy.size.width, color: .orange)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                HStack(spacing: 14) {
                    legend("Images", breakdown.imagesBytes, reclaimable: breakdown.imagesReclaimable, color: .blue)
                    legend("Containers", breakdown.containersBytes, reclaimable: 0, color: .green)
                    legend("Volumes", breakdown.volumesBytes, reclaimable: breakdown.volumesReclaimable, color: .purple)
                    legend("Build cache", breakdown.buildCacheBytes, reclaimable: breakdown.buildCacheReclaimable, color: .orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(store.engineReady ? "Measuring… (docker scans its storage for this)" : "Engine offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func segment(_ value: UInt64, of total: UInt64, width: CGFloat, color: Color) -> some View {
        Rectangle().fill(color)
            .frame(width: total > 0 ? width * CGFloat(value) / CGFloat(total) : 0)
    }

    private func legend(_ label: String, _ bytes: UInt64, reclaimable: UInt64, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(label) \(Self.bytes(bytes))").font(.caption2).foregroundStyle(.secondary)
            if reclaimable > 0 {
                Text("(\(Self.bytes(reclaimable)) reclaimable)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Formatting

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1
            ? "0"
            : ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// Minimal sparkline over 0…1 samples; rendered as a plain SwiftUI Path so no
/// charting dependency is needed.
struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let stepX = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(
                x: rect.minX + CGFloat(index) * stepX,
                y: rect.maxY - CGFloat(min(1, max(0, value))) * rect.height
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
