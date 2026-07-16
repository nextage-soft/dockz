import SwiftUI

/// Drill-in detail page for one container: overview, env, mounts, logs, inspect.
struct ContainerDetailView: View {
    @ObservedObject var store: DashboardStore
    let container: ContainerSummary

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $store.detailTab) {
                Text("Overview").tag(0)
                Text("Environment").tag(1)
                Text("Mounts").tag(2)
                Text("Logs").tag(3)
                Text("Inspect").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(10)
            Divider()
            tabContent
        }
        .navigationTitle(container.name)
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
            actionButtons
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

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button { store.beginEditContainer(container) } label: { Image(systemName: "pencil") }.help("Edit & Recreate")
            if container.isRunning {
                Button { store.openContainerTerminal(container) } label: { Image(systemName: "terminal") }.help("Open terminal (exec)")
                Button { store.containerAction("stop", container) } label: { Image(systemName: "stop.fill") }.help("Stop")
                Button { store.containerAction("restart", container) } label: { Image(systemName: "arrow.clockwise") }.help("Restart")
            } else {
                Button { store.containerAction("start", container) } label: { Image(systemName: "play.fill") }.help("Start")
            }
            Button { store.reloadDetail() } label: { Image(systemName: "arrow.triangle.2.circlepath") }.help("Reload detail")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch store.detailTab {
        case 0: overviewTab
        case 1: monospaceList(store.containerDetail?.environment ?? [], empty: "No environment variables")
        case 2: mountsTab
        case 3: logView(store.detailLogs)
        default: logView(store.detailInspectJSON)
        }
    }

    private var overviewTab: some View {
        Form {
            if let detail = store.containerDetail {
                Section("State") {
                    LabeledContent("Status", value: detail.state)
                    LabeledContent("Started", value: detail.startedAt)
                    LabeledContent("Created", value: detail.createdAt)
                    Picker("Restart policy", selection: restartPolicyBinding(current: detail.restartPolicy)) {
                        Text("no").tag("no")
                        Text("always").tag("always")
                        Text("unless-stopped").tag("unless-stopped")
                        Text("on-failure").tag("on-failure")
                    }
                }
                Section("Runtime") {
                    LabeledContent("Image", value: detail.image)
                    LabeledContent("Command", value: detail.command.isEmpty ? "—" : detail.command)
                    LabeledContent("Working dir", value: detail.workingDir.isEmpty ? "—" : detail.workingDir)
                    LabeledContent("IP address", value: detail.ipAddress.isEmpty ? "—" : detail.ipAddress)
                }
                if !detail.ports.isEmpty {
                    Section("Ports") {
                        ForEach(detail.ports) { port in
                            LabeledContent(port.containerPort, value: port.hostBinding)
                        }
                    }
                }
                if !detail.labels.isEmpty {
                    Section("Labels") {
                        ForEach(detail.labels.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: detail.labels[key] ?? "")
                        }
                    }
                }
            } else {
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

    private func monospaceList(_ items: [String], empty: String) -> some View {
        List(items, id: \.self) { item in
            Text(item)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .overlay {
            if items.isEmpty { Text(empty).foregroundStyle(.secondary) }
        }
    }

    /// Selecting a new value applies it immediately via /containers/{id}/update.
    private func restartPolicyBinding(current: String) -> Binding<String> {
        Binding(
            get: { current.isEmpty ? "no" : current },
            set: { newValue in
                if newValue != current { store.updateRestartPolicy(newValue) }
            }
        )
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
