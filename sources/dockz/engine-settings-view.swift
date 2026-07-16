import SwiftUI

/// Docker engine configuration — edits /etc/docker/daemon.json inside the
/// guest over the vsock shell and restarts dockerd to apply.
struct EngineSettingsView: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("daemon.json").font(.headline)
                    Text("Docker engine configuration (registry-mirrors, insecure-registries, log-opts, …)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload") { store.loadEngineConfig() }
                Button("Validate & Apply") { store.applyEngineConfig() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.engineReady)
            }
            .padding(12)
            Divider()
            TextEditor(text: $store.engineConfigText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack {
                if !store.engineStatus.isEmpty {
                    Text(store.engineStatus)
                        .font(.caption)
                        .foregroundStyle(store.engineStatus.contains("Invalid") ? .red : .secondary)
                }
                Spacer()
                Text("Applying restarts dockerd — running containers will restart.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .navigationTitle("Engine")
        .onAppear {
            if store.engineConfigText == "{}" { store.loadEngineConfig() }
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
