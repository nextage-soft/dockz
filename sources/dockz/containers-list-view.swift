import SwiftUI

struct ContainersListView: View {
    @ObservedObject var store: DashboardStore
    @State private var logsContainer: ContainerSummary?
    @State private var showRunForm = false
    @State private var searchText = ""
    @State private var pendingRemoval: ContainerSummary?
    @State private var collapsedStacks: Set<String> = []
    @AppStorage("dockz.list.containers.scope") private var scope = "all"
    @AppStorage("dockz.list.containers.sort") private var sort = "status"
    @AppStorage("dockz.list.containers.groupByStack") private var groupByStack = true

    private let filter = ListFilters.containers

    private var visible: [ContainerSummary] {
        filter.apply(store.containers, scope: scope, query: searchText, sort: sort)
    }

    /// Compose projects as groups (by name), plain containers last.
    private var groups: [(project: String?, members: [ContainerSummary])] {
        let byProject = Dictionary(grouping: visible, by: \.composeProject)
        let stacks = byProject.keys.compactMap { $0 }.sorted(by: namesAscending)
        var result = stacks.map { (project: Optional($0), members: byProject[$0] ?? []) }
        if let plain = byProject[nil], !plain.isEmpty { result.append((project: nil, members: plain)) }
        return result
    }

    var body: some View {
        Group {
            if store.containers.isEmpty {
                EmptyStateView(
                    icon: "shippingbox",
                    title: "No containers yet",
                    hint: "Run your first container — the image is pulled automatically.",
                    actionLabel: "Run Container…"
                ) { showRunForm = true }
            } else {
                VStack(spacing: 0) {
                    ListHeaderBar(
                        summary: "",
                        prompt: "Filter by name, image or stack",
                        searchText: $searchText,
                        scopes: filter.options(for: store.containers, query: searchText),
                        scope: $scope
                    ) {
                        ListSortMenu(options: filter.sortOptions, selection: $sort) {
                            Divider()
                            Toggle("Group by Stack", isOn: $groupByStack)
                        }
                        Button {
                            showRunForm = true
                        } label: {
                            Label("Run", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("n", modifiers: .command)
                        .disabled(!store.engineReady)
                        .help("Run a new container (⌘N)")
                    }
                    Divider()
                    if visible.isEmpty {
                        noMatches
                    } else {
                        List {
                            if groupByStack {
                                ForEach(groups, id: \.project) { group in
                                    Section {
                                        if !collapsedStacks.contains(group.project ?? "") {
                                            ForEach(group.members) { row($0) }
                                        }
                                    } header: {
                                        groupHeader(group.project, members: group.members)
                                    }
                                }
                            } else {
                                ForEach(visible) { row($0) }
                            }
                        }
                        .listStyle(.inset)
                    }
                }
            }
        }
        .navigationTitle("Containers")
        .sheet(item: $logsContainer) { container in
            LogsSheet(title: container.name, store: store, container: container)
        }
        .sheet(isPresented: $showRunForm) {
            RunContainerFormView(store: store, mode: .run)
        }
        .confirmationDialog(
            "Remove container \"\(pendingRemoval?.name ?? "")\"\(store.targetSuffix)?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove (force)", role: .destructive) {
                if let container = pendingRemoval { store.removeContainer(container) }
                pendingRemoval = nil
            }
        } message: {
            Text("The container is stopped and deleted. Data outside volumes is lost.")
        }
    }

    private func row(_ container: ContainerSummary) -> some View {
        ContainerRow(
            container: container,
            isBusy: store.busyIDs.contains(container.id),
            onAction: { verb in store.containerAction(verb, container) },
            onRemove: { pendingRemoval = container },
            onLogs: { logsContainer = container },
            onEdit: { store.beginEditContainer(container) },
            onOpen: { store.openDetail(for: container) }
        )
        .listRowSeparator(.hidden)
    }

    /// Stack name, how much of it runs, and a collapse toggle.
    private func groupHeader(_ project: String?, members: [ContainerSummary]) -> some View {
        let key = project ?? ""
        let collapsed = collapsedStacks.contains(key)
        let running = members.filter(\.isRunning).count
        return Button {
            if collapsed { collapsedStacks.remove(key) } else { collapsedStacks.insert(key) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                Image(systemName: project == nil ? "shippingbox" : "rectangle.3.group")
                    .foregroundStyle(.secondary)
                Text(project ?? "Standalone containers")
                    .font(.callout.weight(.semibold))
                Text("\(running)/\(members.count) running")
                    .font(.caption)
                    .foregroundStyle(running == members.count ? Color.green : .secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var noMatches: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No containers match").font(.headline)
            Button("Show All") {
                scope = "all"
                searchText = ""
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ContainerRow: View {
    let container: ContainerSummary
    let isBusy: Bool
    let onAction: (String) -> Void
    let onRemove: () -> Void
    let onLogs: () -> Void
    let onEdit: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ContainerAvatar(name: container.name, running: container.isRunning, imageRef: container.image)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(container.name)
                        .font(.system(.body, weight: .semibold))
                    StatusChip(state: container.displayState)
                    if let health = container.health {
                        HealthChip(health: health)
                    }
                }
                HStack(spacing: 8) {
                    Label(container.imageLabel, systemImage: "square.stack.3d.up")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(container.image)
                    Text(container.statusText)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !container.publicTCPPorts.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(container.publicTCPPorts, id: \.self) { port in
                            PortBadge(port: port)
                        }
                    }
                }
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                actionButtons
                    .opacity(hovering ? 1 : 0.45)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(hovering ? Color.primary.opacity(0.05) : Color.primary.opacity(0.02))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if container.isRunning {
                iconButton("stop.fill", help: "Stop") { onAction("stop") }
                iconButton("arrow.clockwise", help: "Restart") { onAction("restart") }
            } else {
                iconButton("play.fill", help: "Start") { onAction("start") }
            }
            iconButton("doc.text", help: "Logs", action: onLogs)
            iconButton("pencil", help: "Edit & Recreate", action: onEdit)
            iconButton("trash", help: "Remove…", action: onRemove)
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.help(help)
    }
}

/// Container/image avatar: the Docker Hub logo of the image when available
/// (white tile like Docker Desktop), otherwise a deterministic gradient with
/// the name's initials.
struct ContainerAvatar: View {
    let name: String
    let running: Bool
    var imageRef: String?
    @State private var logo: NSImage?

    private var hue: Double {
        let hash = name.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }
        return Double(abs(hash) % 360) / 360.0
    }

    var body: some View {
        Group {
            if let logo {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white)
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hue: hue, saturation: 0.55, brightness: running ? 0.85 : 0.45),
                                    Color(hue: hue, saturation: 0.75, brightness: running ? 0.65 : 0.35),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(String(name.prefix(2)).uppercased())
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 34, height: 34)
        .saturation(running ? 1 : 0.45)
        .onAppear {
            guard logo == nil, let imageRef else { return }
            ImageLogoLoader.shared.load(imageRef: imageRef) { logo = $0 }
        }
    }
}

struct StatusChip: View {
    let state: String

    private var color: Color {
        switch state {
        case "running": return .green
        case "paused": return .yellow
        case "restarting": return .orange
        case "dead", "crashed": return .red
        default: return .secondary
        }
    }

    var body: some View {
        Text(state)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

/// Healthcheck result as its own chip, so "unhealthy" stands out.
struct HealthChip: View {
    let health: ContainerSummary.Health

    var body: some View {
        let (text, color): (String, Color) = switch health {
        case .healthy: ("healthy", .green)
        case .unhealthy: ("unhealthy", .red)
        case .starting: ("starting", .yellow)
        }
        Label(text, systemImage: health == .unhealthy ? "heart.slash" : "heart")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

struct PortBadge: View {
    let port: Int

    var body: some View {
        Button {
            if let url = URL(string: "http://localhost:" + String(port)) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            // String(port), not \(port): SwiftUI Text localizes Int
            // interpolation (5432 would render as "5.432").
            Label(":" + String(port), systemImage: "globe")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.blue.opacity(0.14)))
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .help("Open localhost:\(port) in the browser")
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let hint: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.medium))
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
