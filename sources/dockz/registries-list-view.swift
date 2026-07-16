import SwiftUI

/// Registry management: Docker Hub account and any custom/private registries.
/// Credentials go to the macOS Keychain; pulls from the UI attach
/// X-Registry-Auth automatically for matching registries.
struct RegistriesListView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var registries: RegistryStore
    @State private var editing: RegistryEntry?
    @State private var showAdd = false
    @State private var pendingRemoval: RegistryEntry?

    init(store: DashboardStore) {
        self.store = store
        self.registries = store.registries
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(registries.entries.count) \(registries.entries.count == 1 ? "registry" : "registries")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showAdd = true
                } label: {
                    Label("Add Registry", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if registries.entries.isEmpty {
                EmptyStateView(
                    icon: "key",
                    title: "No registries",
                    hint: "Add Docker Hub or a private registry to pull private images from the UI.\nThe docker CLI keeps using its own `docker login` credentials.",
                    actionLabel: "Add Registry…"
                ) { showAdd = true }
            } else {
                List(registries.entries) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showAdd) {
            RegistryFormSheet(registries: registries, entry: nil)
        }
        .sheet(item: $editing) { entry in
            RegistryFormSheet(registries: registries, entry: entry)
        }
        .confirmationDialog(
            "Remove registry \"\(pendingRemoval?.name ?? "")\"?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove — credentials are deleted from Keychain", role: .destructive) {
                if let entry = pendingRemoval { registries.remove(entry) }
                pendingRemoval = nil
            }
        }
    }

    private func row(_ entry: RegistryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDockerHub ? "shippingbox.circle.fill" : "server.rack")
                .font(.title3)
                .foregroundStyle(.blue.opacity(0.8))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.name).font(.system(.body, weight: .semibold))
                    if entry.insecure {
                        Text("http")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(entry.server)  ·  \(entry.username.isEmpty ? "anonymous" : entry.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status = registries.statuses[entry.id] {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.hasPrefix("Connected") ? .green : .orange)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                Button("Test") { test(entry) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button {
                    editing = entry
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit")
                Button {
                    pendingRemoval = entry
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove…")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func test(_ entry: RegistryEntry) {
        registries.statuses[entry.id] = "Testing…"
        let password = RegistryStore.password(server: entry.server, username: entry.username)
        RegistryAuth.testConnection(entry: entry, password: password) { status in
            DispatchQueue.main.async { registries.statuses[entry.id] = status }
        }
    }
}

private struct RegistryFormSheet: View {
    @ObservedObject var registries: RegistryStore
    let entry: RegistryEntry?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var insecure = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry == nil ? "Add Registry" : "Edit Registry").font(.headline)
                Spacer()
            }
            .padding(14)
            Divider()
            VStack(spacing: 10) {
                LabeledField("Name") {
                    TextField("", text: $name, prompt: Text("Company GitLab"))
                }
                LabeledField("Server", required: true) {
                    TextField("", text: $server, prompt: Text("docker.io or registry.company.com:5000"))
                }
                LabeledField("Username") {
                    TextField("", text: $username, prompt: Text("anonymous if blank"))
                }
                LabeledField("Password") {
                    SecureField("", text: $password, prompt: Text(entry == nil ? "token or password" : "unchanged if blank"))
                }
                LabeledField("") {
                    Toggle("Plain HTTP registry (insecure)", isOn: $insecure)
                }
                if insecure {
                    Text("HTTP registries (except localhost) must also be listed in Engine → daemon.json `insecure-registries`.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520)
        .onAppear {
            guard let entry else { return }
            name = entry.name
            server = entry.server
            username = entry.username
            insecure = entry.insecure
        }
    }

    private func save() {
        let trimmedServer = server.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var updated = entry ?? RegistryEntry(name: "", server: "", username: "")
        updated.name = name.isEmpty ? trimmedServer : name
        updated.server = trimmedServer
        updated.username = username.trimmingCharacters(in: .whitespaces)
        updated.insecure = insecure
        registries.upsert(updated, password: password)
        dismiss()
    }
}
