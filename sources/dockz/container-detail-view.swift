import SwiftUI

/// Drill-in detail page for one container: overview, env, mounts, logs, inspect.
struct ContainerDetailView: View {
    @ObservedObject var store: DashboardStore
    let container: ContainerSummary

    @State private var confirmRemove = false

    var body: some View {
        VStack(spacing: 0) {
            header
            actionBar
            Divider()
            Picker("", selection: $store.detailTab) {
                Text("Overview").tag(0)
                Text("Mounts").tag(1)
                Text("Logs").tag(2)
                Text("Inspect").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(10)
            Divider()
            tabContent
        }
        .navigationTitle(container.name)
        .confirmationDialog("Remove \(container.name)?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove — data outside volumes is lost", role: .destructive) {
                store.removeContainer(container)
                store.closeDetail()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                store.closeDetail()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back to list")
            ContainerAvatar(name: container.name, running: container.isRunning, imageRef: container.image)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(container.name).font(.title3.weight(.semibold))
                    StatusChip(state: container.state)
                }
                HStack(spacing: 8) {
                    Text("\(container.shortID)  ·  \(container.image)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(container.publicTCPPorts, id: \.self) { port in
                        PortBadge(port: port)
                    }
                }
            }
            Spacer()
            statsBadge
        }
        .padding(12)
    }

    private var statsBadge: some View {
        Group {
            if let stats = store.containerStats, container.isRunning {
                HStack(spacing: 8) {
                    StatPill(icon: "cpu", value: String(format: "%.1f%%", stats.cpuPercent))
                    StatPill(icon: "memorychip", value: stats.memoryLabel)
                }
            }
        }
    }

    /// Portainer-style full action row: lifecycle verbs left, config actions right.
    private var actionBar: some View {
        HStack(spacing: 6) {
            if container.isRunning || container.state == "paused" {
                if container.state == "paused" {
                    actionButton("Resume", icon: "play.fill") { store.containerAction("unpause", container) }
                } else {
                    actionButton("Pause", icon: "pause.fill") { store.containerAction("pause", container) }
                    actionButton("Stop", icon: "stop.fill") { store.containerAction("stop", container) }
                }
                actionButton("Restart", icon: "arrow.clockwise") { store.containerAction("restart", container) }
                actionButton("Kill", icon: "bolt.fill") { store.containerAction("kill", container) }
            } else {
                actionButton("Start", icon: "play.fill") { store.containerAction("start", container) }
            }
            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .controlSize(.small)

            Divider().frame(height: 16)

            actionButton("Edit & Recreate", icon: "pencil") { store.beginEditContainer(container) }
            actionButton("Duplicate", icon: "plus.square.on.square") { store.beginDuplicateContainer(container) }
            if container.isRunning {
                actionButton("Shell", icon: "terminal") { store.openContainerTerminal(container) }
            }
            Spacer()
            Button {
                store.reloadDetail()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Reload detail")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch store.detailTab {
        case 0: overviewTab
        case 1: mountsTab
        case 2: logView(store.detailLogs)
        default: logView(store.detailInspectJSON)
        }
    }

    @ViewBuilder
    private var overviewTab: some View {
        if let detail = store.containerDetail {
            ContainerOverviewCards(store: store, container: container, detail: detail)
        } else {
            VStack {
                Spacer()
                Text("Loading…").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var mountsTab: some View {
        List(store.containerDetail?.mounts ?? []) { mount in
            VStack(alignment: .leading, spacing: 2) {
                Text(mount.destination).font(.system(.body, design: .monospaced))
                Text("\(mount.source)  ·  \(mount.mode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if store.containerDetail?.mounts.isEmpty != false {
                Text("No mounts").foregroundStyle(.secondary)
            }
        }
    }

    private func logView(_ text: String) -> some View {
        TerminalTextView(text: text)
    }
}

struct StatPill: View {
    let icon: String
    let value: String

    var body: some View {
        Label(value, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}
