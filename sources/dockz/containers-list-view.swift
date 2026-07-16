import SwiftUI

struct ContainersListView: View {
    @ObservedObject var store: DashboardStore
    @State private var logsContainer: ContainerSummary?
    @State private var showRunForm = false
    @State private var searchText = ""
    @State private var pendingRemoval: ContainerSummary?

    private var filtered: [ContainerSummary] {
        guard !searchText.isEmpty else { return store.containers }
        let query = searchText.lowercased()
        return store.containers.filter {
            $0.name.lowercased().contains(query) || $0.image.lowercased().contains(query)
        }
    }

    private var summaryText: String {
        let total = store.containers.count
        let running = store.containers.filter(\.isRunning).count
        return "\(total) \(total == 1 ? "container" : "containers") · \(running) running"
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
                        summary: summaryText,
                        prompt: "Filter by name or image",
                        searchText: $searchText
                    ) {
                        Button {
                            showRunForm = true
                        } label: {
                            Label("Run", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.engineReady)
                        .help("Run a new container")
                    }
                    Divider()
                    List(filtered) { container in
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
                    .listStyle(.inset)
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
            "Remove container \"\(pendingRemoval?.name ?? "")\"?",
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
                    StatusChip(state: container.state)
                }
                HStack(spacing: 8) {
                    Label(container.image, systemImage: "square.stack.3d.up")
                        .lineLimit(1)
                    Text(container.status)
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
        case "dead": return .red
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
