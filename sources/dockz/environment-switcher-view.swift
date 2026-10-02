import SwiftUI

/// Sidebar control choosing which engine every tab shows. ⌘1 is Local and
/// ⌘2…⌘9 the added environments in list order.
struct EnvironmentSwitcher: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var environments: EnvironmentStore
    let collapsed: Bool

    init(store: DashboardStore, collapsed: Bool) {
        self.store = store
        self.environments = store.environments
        self.collapsed = collapsed
    }

    var body: some View {
        Menu {
            Button {
                store.switchEnvironment(to: nil)
            } label: {
                Label("Local (DockZ VM)", systemImage: environments.isLocal ? "checkmark" : "desktopcomputer")
            }
            .keyboardShortcut("1", modifiers: .command)
            if !environments.environments.isEmpty { Divider() }
            ForEach(Array(environments.environments.enumerated()), id: \.element.id) { index, environment in
                let button = Button {
                    store.switchEnvironment(to: environment.id)
                } label: {
                    Label("\(environment.name) — \(Self.statusText(environments.status(of: environment.id)))",
                          systemImage: environments.selectedID == environment.id ? "checkmark" : "server.rack")
                }
                if index < 8 {
                    button.keyboardShortcut(KeyEquivalent(Character(String(index + 2))), modifiers: .command)
                } else {
                    button
                }
            }
            Divider()
            Button("Manage Environments…") { store.requestedSection = .environments }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(collapsed ? .hidden : .visible)
        // Menu-item shortcuts only fire while the menu is open; these make
        // ⌘1…⌘9 work any time the dashboard is focused.
        .background { shortcutButtons }
        .help("Environment — which Docker engine the dashboard shows")
        .onAppear { environments.checkAll() }
    }

    private var shortcutButtons: some View {
        ZStack {
            Button("") { store.switchEnvironment(to: nil) }
                .keyboardShortcut("1", modifiers: .command)
            ForEach(Array(environments.environments.prefix(8).enumerated()), id: \.element.id) { index, environment in
                Button("") { store.switchEnvironment(to: environment.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 2))), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var label: some View {
        let selected = environments.selected
        if collapsed {
            Circle().fill(dotColor(selected)).frame(width: 10, height: 10)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 8) {
                Circle().fill(dotColor(selected)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(selected?.name ?? "Local").font(.callout.weight(.semibold)).lineLimit(1)
                    Text(selected?.summary ?? "DockZ VM on this Mac")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func dotColor(_ environment: DockerEnvironment?) -> Color {
        guard let environment else { return store.engineReady ? .green : .secondary }
        switch environments.status(of: environment.id) {
        case .online: return .green
        case .checking, .unknown: return .orange
        case .offline: return .red
        case .locked: return .secondary
        }
    }

    static func statusText(_ status: EnvironmentStore.Status) -> String {
        switch status {
        case .unknown: return "not checked"
        case .checking: return "checking…"
        case .online(let info): return "Docker \(info.serverVersion)"
        case .offline: return "offline"
        case .locked: return "locked · Touch ID to connect"
        }
    }
}
