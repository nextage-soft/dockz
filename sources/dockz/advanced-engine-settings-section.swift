import SwiftUI

/// Settings → Advanced: the local VM's Docker engine configuration. Edits
/// /etc/docker/daemon.json inside the guest over the vsock shell and restarts
/// dockerd to apply. Collapsed by default — most users never need it.
struct AdvancedEngineSettingsSection: View {
    @ObservedObject var store: DashboardStore
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Docker engine configuration (registry-mirrors, insecure-registries, log-opts, …). Invalid JSON is rejected before anything is written.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $store.engineConfigText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .frame(minHeight: 220)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12)))
                    HStack {
                        if !store.engineStatus.isEmpty {
                            Text(store.engineStatus)
                                .font(.caption)
                                .foregroundStyle(store.engineStatus.contains("Invalid") ? .red : .secondary)
                        }
                        Spacer()
                        Button("Reload") { store.loadEngineConfig() }
                        Button("Validate & Apply") { store.applyEngineConfig() }
                            .disabled(!store.engineReady)
                    }
                    Text("Applying restarts dockerd — running containers will restart.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 6)
            } label: {
                Label("Docker engine (daemon.json)", systemImage: "slider.horizontal.3")
            }
            .onChange(of: expanded) { isExpanded in
                if isExpanded, store.engineConfigText == "{}" { store.loadEngineConfig() }
            }
        } header: {
            Text("Advanced")
        }
    }
}

/// Example daemon.json shown in docs/help:
/// {
///   "registry-mirrors": ["https://mirror.gcr.io"],
///   "insecure-registries": ["registry.local:5000"],
///   "log-driver": "json-file",
///   "log-opts": { "max-size": "10m", "max-file": "3" }
/// }
