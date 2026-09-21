import SwiftUI

/// Portainer-style overview for one container: paired cards for status and
/// runtime details, key–value tables for env/ports/labels with per-section
/// Edit buttons (all of which require a recreate, so they open the Edit &
/// Recreate form), and the live-editable networks card.
struct ContainerOverviewCards: View {
    @ObservedObject var store: DashboardStore
    let container: ContainerSummary
    let detail: ContainerDetail

    /// Env values whose eye icon has been clicked open.
    @State private var revealedKeys: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    statusCard
                    detailsCard
                }
                environmentCard
                HStack(alignment: .top, spacing: 10) {
                    portsCard
                    labelsCard
                }
                networksCard
            }
            .padding(12)
        }
    }

    // MARK: - Status / Details

    private var statusCard: some View {
        card("Status") {
            row("State", "\(detail.state) · \(container.status)")
            row("Created", detail.createdAt)
            row("Started", detail.startedAt)
            HStack {
                Text("Restart policy").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: restartPolicyBinding) {
                    Text("no").tag("no")
                    Text("always").tag("always")
                    Text("unless-stopped").tag("unless-stopped")
                    Text("on-failure").tag("on-failure")
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 140)
            }
            row("IP", detail.ipAddress, monospaced: true)
        }
    }

    private var detailsCard: some View {
        card("Details") {
            row("Image", detail.image, monospaced: true)
            row("Command", detail.command, monospaced: true)
            row("Working dir", detail.workingDir, monospaced: true)
            row("User", detail.user)
            row("Hostname", detail.hostname, monospaced: true)
        }
    }

    // MARK: - Environment (masked secrets)

    /// Conventional secret-bearing key fragments; matching values render
    /// masked until the eye icon is clicked.
    static func isSensitiveKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return ["PASSWORD", "PASSWD", "SECRET", "TOKEN", "KEY", "CREDENTIAL"]
            .contains { upper.contains($0) }
    }

    private var environmentCard: some View {
        card("Environment (\(detail.environment.count))", editable: true) {
            if detail.environment.isEmpty {
                Text("No environment variables").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(detail.environment, id: \.self) { entry in
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                let key = parts.first ?? entry
                let value = parts.count > 1 ? parts[1] : ""
                let sensitive = Self.isSensitiveKey(key)
                let revealed = revealedKeys.contains(key)
                HStack(spacing: 6) {
                    Text(key)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Text(sensitive && !revealed ? "••••••••" : value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if sensitive {
                        Button {
                            if revealed { revealedKeys.remove(key) } else { revealedKeys.insert(key) }
                        } label: {
                            Image(systemName: revealed ? "eye.slash" : "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(revealed ? "Hide value" : "Reveal value")
                    }
                }
            }
        }
    }

    // MARK: - Ports / Labels

    private var portsCard: some View {
        card("Ports (\(detail.ports.count))", editable: true) {
            if detail.ports.isEmpty {
                Text("No published ports").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(detail.ports) { port in
                row(port.containerPort, port.hostBinding, monospaced: true)
            }
        }
    }

    private var labelsCard: some View {
        card("Labels (\(detail.labels.count))", editable: true) {
            if detail.labels.isEmpty {
                Text("No labels").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(detail.labels.keys.sorted(), id: \.self) { key in
                row(key, detail.labels[key] ?? "", monospaced: true)
            }
        }
    }

    // MARK: - Networks (live connect/disconnect — no recreate needed)

    private var networksCard: some View {
        card("Networks (\(detail.networks.count))") {
            ForEach(detail.networks) { network in
                HStack {
                    Label(network.name, systemImage: "network").font(.caption)
                    Spacer()
                    Text(network.ipAddress.isEmpty ? "—" : network.ipAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Disconnect") {
                        store.disconnectNetwork(network.name, container: container)
                    }
                    .controlSize(.small)
                    .disabled(detail.networks.count == 1)
                    .help(detail.networks.count == 1
                          ? "A container needs at least one network"
                          : "Leave \(network.name)")
                }
            }
            let joined = Set(detail.networks.map(\.name))
            let available = store.networks.map(\.name)
                .filter { !joined.contains($0) && $0 != "none" && $0 != "host" }
            if !available.isEmpty {
                Menu("Connect to network…") {
                    ForEach(available, id: \.self) { name in
                        Button(name) { store.connectNetwork(name, container: container) }
                    }
                }
                .frame(maxWidth: 220)
            }
        }
    }

    // MARK: - Card chrome

    /// `editable` sections need a recreate to change, so their Edit button
    /// opens the shared Edit & Recreate form — one form, many entry points.
    private func card(_ title: String, editable: Bool = false,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                if editable {
                    Button {
                        store.beginEditContainer(container)
                    } label: {
                        Label("Edit", systemImage: "pencil").font(.caption)
                    }
                    .controlSize(.small)
                    .help("Opens Edit & Recreate — changing this requires recreating the container")
                }
            }
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    /// Selecting a new value applies immediately via /containers/{id}/update.
    private var restartPolicyBinding: Binding<String> {
        Binding(
            get: { detail.restartPolicy.isEmpty ? "no" : detail.restartPolicy },
            set: { newValue in
                if newValue != detail.restartPolicy { store.updateRestartPolicy(newValue) }
            }
        )
    }
}
