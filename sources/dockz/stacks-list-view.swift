import AppKit
import SwiftUI

/// Compose stacks tab: deploy compose files, tear stacks down, see per-stack
/// container status. Discovered stacks (deployed elsewhere) show up too.
struct StacksListView: View {
    @ObservedObject var store: DashboardStore
    @State private var pendingDown: StackRow?
    @State private var editorPayload: StackEditorPayload?

    struct StackEditorPayload: Identifiable {
        let id = UUID()
        var name: String
        var yaml: String
        var existingPath: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                let count = store.stackRows.count
                Text("\(count) \(count == 1 ? "stack" : "stacks")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button {
                        editorPayload = StackEditorPayload(name: "", yaml: Self.templateYAML, existingPath: nil)
                    } label: {
                        Label("New Stack (Editor)…", systemImage: "square.and.pencil")
                    }
                    Button {
                        pickComposeFile()
                    } label: {
                        Label("From Compose File…", systemImage: "folder")
                    }
                } label: {
                    Label("Add Stack", systemImage: "plus")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .disabled(!store.engineReady || store.composeRunning)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if store.stackRows.isEmpty {
                EmptyStateView(
                    icon: "rectangle.3.group",
                    title: "No stacks",
                    hint: "Deploy a docker-compose.yaml — services, networks and volumes are created together.",
                    actionLabel: "Deploy Compose File…"
                ) { pickComposeFile() }
            } else {
                List(store.stackRows) { row in
                    stackRow(row)
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $store.showComposeOutput) {
            ComposeOutputSheet(store: store)
        }
        .sheet(item: $editorPayload) { payload in
            StackEditorSheet(store: store, payload: payload)
        }
        .confirmationDialog(
            "Tear down stack \"\(pendingDown?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDown != nil }, set: { if !$0 { pendingDown = nil } }),
            titleVisibility: .visible
        ) {
            Button("Down — containers and networks are removed", role: .destructive) {
                if let row = pendingDown {
                    store.showComposeOutput = true
                    store.stackDown(name: row.name)
                }
                pendingDown = nil
            }
        }
    }

    private func stackRow(_ row: StackRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.title3)
                .foregroundStyle(.purple.opacity(0.8))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.name).font(.system(.body, weight: .semibold))
                    if row.totalCount > 0 {
                        Text("\(row.runningCount)/\(row.totalCount) running")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(row.runningCount > 0 ? Color.green.opacity(0.16) : Color.secondary.opacity(0.16)))
                            .foregroundStyle(row.runningCount > 0 ? .green : .secondary)
                    } else {
                        Text("not deployed")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(row.composePath ?? "discovered from labels (compose file unknown)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                let services = store.containers(inStack: row.name).compactMap(\.composeService)
                if !services.isEmpty {
                    Text(services.sorted().joined(separator: " · "))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                if let path = row.composePath {
                    Button {
                        let yaml = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                        editorPayload = StackEditorPayload(name: row.name, yaml: yaml, existingPath: path)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("Edit compose YAML")
                    .disabled(store.composeRunning)
                    Button {
                        store.showComposeOutput = true
                        store.stackUp(name: row.name, composePath: path)
                    } label: {
                        Image(systemName: "arrow.up.circle")
                    }
                    .help("docker compose up -d")
                    .disabled(store.composeRunning)
                }
                if row.totalCount > 0 {
                    Button {
                        pendingDown = row
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .help("docker compose down…")
                    .disabled(store.composeRunning)
                }
                if row.composePath != nil {
                    Button {
                        store.removeStackFile(named: row.name)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Forget stack (does not touch running containers)")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    static let templateYAML = """
    services:
      web:
        image: nginx:alpine
        ports:
          - "8080:80"
    """

    private func pickComposeFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.yaml]
        panel.message = "Choose a docker-compose file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let defaultName = url.deletingLastPathComponent().lastPathComponent
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        store.addStackFile(name: defaultName, composePath: url.path)
        store.showComposeOutput = true
        store.stackUp(name: defaultName, composePath: url.path)
    }
}

/// Portainer-style web editor: type/paste compose YAML and deploy directly.
/// New stacks are saved under ~/.dockz/stacks/<name>/compose.yaml.
private struct StackEditorSheet: View {
    @ObservedObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var yaml: String
    private let existingPath: String?

    init(store: DashboardStore, payload: StacksListView.StackEditorPayload) {
        self.store = store
        self.existingPath = payload.existingPath
        _name = State(initialValue: payload.name)
        _yaml = State(initialValue: payload.yaml)
    }

    private var sanitizedName: String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group")
                    .font(.title3)
                    .foregroundStyle(.purple)
                Text(existingPath == nil ? "New Stack" : "Edit Stack — \(name)")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            VStack(spacing: 10) {
                if existingPath == nil {
                    LabeledField("Name", required: true) {
                        TextField("", text: $name, prompt: Text("my-stack"))
                    }
                }
                TextEditor(text: $yaml)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                if let existingPath {
                    Text(existingPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            Divider()
            HStack {
                Text("Deploys with docker compose up -d — services, networks and volumes are created together.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Deploy") { deploy() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sanitizedName.isEmpty || yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.composeRunning)
            }
            .padding(12)
        }
        .frame(width: 660, height: 520)
    }

    private func deploy() {
        store.showComposeOutput = true
        store.deployStackFromEditor(name: sanitizedName, yaml: yaml, existingPath: existingPath)
        dismiss()
    }
}

private struct ComposeOutputSheet: View {
    @ObservedObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("docker compose \(store.composeTitle)", systemImage: "rectangle.3.group")
                    .font(.headline)
                Spacer()
                if store.composeRunning {
                    ProgressView().controlSize(.small)
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.composeRunning)
            }
            .padding(12)
            Divider()
            TerminalTextView(text: store.composeOutput)
        }
        .frame(width: 720, height: 440)
    }
}
