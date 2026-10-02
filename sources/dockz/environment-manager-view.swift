import SwiftUI

/// Sidebar page listing the engines DockZ can manage: add / edit / remove,
/// switch, and a live connection test (in the editor) before saving.
struct EnvironmentManagerView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var environments: EnvironmentStore
    @State private var editing: DockerEnvironment?
    @State private var pendingRemoval: DockerEnvironment?
    @State private var searchText = ""
    @AppStorage("dockz.list.environments.scope") private var scope = "all"

    private let filter = ListFilters.environments

    private var filtered: [DockerEnvironment] {
        filter.apply(environments.environments, scope: scope, query: searchText, sort: "name")
    }

    /// Local always exists; it shows unless a search or kind filter excludes it.
    private var showsLocal: Bool {
        scope == "all" && (searchText.isEmpty || "local dockz vm".contains(searchText.lowercased()))
    }

    init(store: DashboardStore) {
        self.store = store
        self.environments = store.environments
    }

    var body: some View {
        VStack(spacing: 0) {
            ListHeaderBar(
                summary: "\(environments.environments.count + 1) environments",
                prompt: "Filter environments",
                searchText: $searchText,
                scopes: environments.environments.isEmpty ? [] : filter.options(for: environments.environments, query: searchText),
                scope: $scope
            ) {
                Button {
                    environments.checkAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Check every environment's status")
                Button {
                    editing = DockerEnvironment(name: "", kind: .ssh, address: "", port: nil)
                } label: {
                    Label("Add Environment", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add an environment (⌘N)")
            }
            Divider()
            List {
                if showsLocal {
                    row(name: "Local", summary: "DockZ VM on this Mac", status: nil, environment: nil)
                }
                ForEach(filtered) { environment in
                    row(name: environment.name, summary: environment.summary,
                        status: environments.status(of: environment.id), environment: environment)
                }
            }
            .listStyle(.inset)
            // Only Local so far: keep its row compact and give the room to the hint.
            .frame(maxHeight: environments.environments.isEmpty ? 64 : .infinity)
            if environments.environments.isEmpty {
                EmptyStateView(
                    icon: "server.rack",
                    title: "No other engines yet",
                    hint: "Add a server over SSH or TLS, or another engine on this Mac (Colima, OrbStack…).\nThe sheet walks you through the setup step by step.",
                    actionLabel: "Add Environment…"
                ) { editing = DockerEnvironment(name: "", kind: .ssh, address: "", port: nil) }
            }
            Text("Nothing is joined or shared — DockZ only talks to each engine's API. Switch with the menu at the top of the sidebar or ⌘1…⌘9.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .onAppear { environments.checkAll() }
        .sheet(item: $editing) { environment in
            EnvironmentEditorView(store: store, draft: environment)
        }
        .confirmationDialog("Remove \(pendingRemoval?.name ?? "")?",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from DockZ", role: .destructive) {
                if let environment = pendingRemoval {
                    if environments.selectedID == environment.id { store.switchEnvironment(to: nil) }
                    environments.remove(environment.id)
                }
                pendingRemoval = nil
            }
        } message: {
            Text("Only DockZ's connection settings are deleted. The engine and its containers are not touched.")
        }
    }

    private func row(name: String, summary: String, status: EnvironmentStore.Status?,
                     environment: DockerEnvironment?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: environment == nil ? "desktopcomputer" : "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let status {
                Text(EnvironmentSwitcher.statusText(status))
                    .font(.caption).foregroundStyle(statusColor(status))
            }
            if environments.selectedID == environment?.id {
                Text("Current")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            } else {
                Button("Switch") { store.switchEnvironment(to: environment?.id) }.controlSize(.small)
            }
            if let environment {
                Button("Edit") { editing = environment }.controlSize(.small)
                Button(role: .destructive) {
                    pendingRemoval = environment
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(environment.name)")
            }
        }
        .padding(.vertical, 2)
    }

    private func statusColor(_ status: EnvironmentStore.Status) -> Color {
        switch status {
        case .online: return .green
        case .offline: return .red
        default: return .secondary
        }
    }
}

/// Form for one environment. For TLS the client key is created in the Secure
/// Enclave here and only its signing request leaves the Mac; the server's CA
/// and the signed certificate (both public) are stored in DockZ's data folder.
struct EnvironmentEditorView: View {
    @ObservedObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: DockerEnvironment
    @State private var portText = ""
    @State private var testResult: EnvironmentStore.Status?
    @State private var certError: String?
    @State private var certRevision = 0
    @State private var signingRequest: String?
    @State private var keyBusy = false
    @State private var confirmReplaceKey = false

    init(store: DashboardStore, draft: DockerEnvironment) {
        self.store = store
        _draft = State(initialValue: draft)
        _portText = State(initialValue: draft.port.map(String.init) ?? "")
    }

    private var certDirectory: URL { EnvironmentCatalog.certDirectory(for: draft.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isExisting ? "Edit Environment" : "Add Environment")
                .font(.headline)
            Picker("", selection: $draft.kind) {
                ForEach(DockerEnvironment.Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 8) {
                        LabeledField("Name", required: true) {
                            TextField("", text: $draft.name, prompt: Text("prod-01"))
                        }
                        switch draft.kind {
                        case .ssh: sshFields
                        case .tls: tlsFields
                        case .socket: socketFields
                        }
                    }
                    testRow
                    Divider()
                    // Re-created per kind so each kind opens in its own state.
                    EnvironmentSetupGuideView(kind: draft.kind, address: draft.address,
                                              port: parsedPort.flatMap { $0 > 0 ? $0 : nil },
                                              expanded: !isExisting)
                        .id(draft.kind)
                }
                .padding(.trailing, 6)
            }
            HStack {
                Button("Cancel") {
                    // A never-saved draft may already have certificates copied in.
                    if !store.environments.environments.contains(where: { $0.id == draft.id }) {
                        EnvironmentCatalog.removeData(for: draft.id)
                    }
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    applyPort()
                    store.environments.save(draft)
                    store.environments.check(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(currentValidationError != nil)
            }
        }
        .padding(18)
        .frame(width: 620, height: 640)
        .onChange(of: draft.kind) { _ in testResult = nil }
        .confirmationDialog("Replace this Mac's key for \(draft.name.isEmpty ? "this environment" : draft.name)?",
                            isPresented: $confirmReplaceKey, titleVisibility: .visible) {
            Button("Replace — the current certificate stops working", role: .destructive) { createKey() }
        }
    }

    private var isExisting: Bool {
        store.environments.environments.contains { $0.id == draft.id }
    }

    // MARK: - Per-kind fields

    private var sshFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledField("Host", required: true) {
                TextField("", text: $draft.address, prompt: Text("deploy@10.0.1.5 or a ~/.ssh/config alias"))
            }
            LabeledField("Port") {
                TextField("", text: $portText, prompt: Text("22 / from ~/.ssh/config")).frame(width: 170)
            }
            Text("Uses your SSH keys, ssh-agent and ~/.ssh/config. Password login isn't supported. The remote user must be able to run docker.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tlsFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledField("Host", required: true) {
                TextField("", text: $draft.address, prompt: Text("10.0.2.8"))
            }
            LabeledField("Port") {
                TextField("", text: $portText, prompt: Text("\(DockerEnvironment.defaultTLSPort)")).frame(width: 120)
            }
            LabeledField("1. Server CA") {
                HStack(spacing: 6) {
                    fileStatus("ca.pem")
                    Button("Paste") { pasteCertificate(as: "ca.pem") }.controlSize(.small)
                    Button("Choose File…") { pickCertificate("ca.pem") }.controlSize(.small)
                }
            }
            LabeledField("2. Mac key") { keyRow }
            if let signingRequest {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run on the server, in the folder with ca.pem and ca-key.pem — it signs this Mac's request and prints the certificate:")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CopyableCommand(text: EnvironmentSetupGuide.signingCommands(for: signingRequest))
                }
                .padding(.leading, 102)
            }
            LabeledField("3. Certificate") {
                HStack(spacing: 6) {
                    fileStatus("cert.pem")
                    Button("Paste") { pasteCertificate(as: "cert.pem") }.controlSize(.small)
                    Button("Choose File…") { pickCertificate("cert.pem") }.controlSize(.small)
                }
            }
            if let certError {
                Text(certError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("This Mac's key is created inside its Secure Enclave: it can't be copied off this Mac, and using it needs Touch ID. Only the public request and certificate are exchanged with the server.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var keyRow: some View {
        let _ = certRevision
        HStack(spacing: 6) {
            if TLSClientKeyVault.hasKey(for: draft.id) {
                Label("In Secure Enclave", systemImage: "lock.shield.fill")
                    .font(.caption).foregroundStyle(.green)
                Button("Show Signing Request") { showSigningRequest() }
                    .controlSize(.small).disabled(keyBusy)
                Button("Replace Key…") { confirmReplaceKey = true }
                    .controlSize(.small).disabled(keyBusy)
            } else {
                Button("Create Key") { createKey() }
                    .controlSize(.small).disabled(keyBusy)
            }
            if keyBusy { ProgressView().controlSize(.small) }
        }
    }

    private func fileStatus(_ name: String) -> some View {
        let _ = certRevision
        let url = certDirectory.appendingPathComponent(name)
        let text = try? String(contentsOf: url, encoding: .utf8)
        var detail = name
        if name == "cert.pem", let text, let expiry = TLSDockerConnector.expiry(of: text) {
            detail = "valid until \(expiry.formatted(date: .abbreviated, time: .omitted))"
        }
        return Label(detail, systemImage: text == nil ? "circle.dashed" : "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(text == nil ? Color.secondary : Color.green)
    }

    // MARK: - TLS key & certificates

    /// New Secure Enclave key, then its signing request (signing it is the
    /// first use, so Touch ID confirms). A previous certificate no longer
    /// matches and is dropped.
    private func createKey() {
        certError = nil
        do {
            try TLSClientKeyVault.shared.createKey(for: draft.id)
            try? FileManager.default.removeItem(at: certDirectory.appendingPathComponent("cert.pem"))
        } catch {
            certError = error.localizedDescription
            return
        }
        certRevision += 1
        testResult = nil
        showSigningRequest()
    }

    private func showSigningRequest() {
        keyBusy = true
        let id = draft.id
        let environment = draft
        store.environments.unlock(environment) { failure in
            keyBusy = false
            if let failure {
                certError = failure
                return
            }
            do {
                let keyURL = TLSClientKeyVault.keyURL(for: id)
                let key = try TLSClientKeyVault.shared.signingKey(for: id, at: keyURL)
                signingRequest = try CertificateSigningRequest.pem(
                    publicKeyInfo: key.publicKey.derRepresentation,
                    commonName: CertificateSigningRequest.defaultCommonName
                ) { try key.signature(for: $0).derRepresentation }
                certError = nil
            } catch {
                certError = error.localizedDescription
            }
        }
    }

    private func pasteCertificate(as name: String) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            certError = "The clipboard has no text — copy the certificate printed on the server first"
            return
        }
        storeCertificate(text, as: name, sourceName: "The clipboard")
    }

    private func pickCertificate(_ name: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose \(name)"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        storeCertificate(String(decoding: data, as: UTF8.self), as: name, sourceName: url.lastPathComponent)
    }

    /// A client certificate must certify this Mac's key — catches one signed
    /// for another request or an older key before any connection attempt.
    private func storeCertificate(_ text: String, as name: String, sourceName: String) {
        do {
            if name == "cert.pem" {
                guard let publicKey = try? TLSClientKeyVault.shared.publicKey(for: draft.id) else {
                    throw DockzError.socketSetupFailed("Create this Mac's key first (step 2)")
                }
                guard TLSDockerConnector.certificate(text, matches: publicKey) else {
                    throw DockzError.socketSetupFailed("\(sourceName) wasn't issued for this Mac's key — sign the current request")
                }
            }
            try EnvironmentCatalog.storeCertificate(text, as: name, for: draft.id, sourceName: sourceName)
            certError = nil
            if name == "cert.pem" { signingRequest = nil }
        } catch {
            certError = error.localizedDescription
        }
        certRevision += 1
        testResult = nil
    }

    private var socketFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledField("Socket", required: true) {
                TextField("", text: $draft.address, prompt: Text("~/.colima/default/docker.sock"))
            }
            let detected = EnvironmentSetupGuide.detectedSockets()
            if !detected.isEmpty {
                LabeledField("Found") {
                    HStack(spacing: 6) {
                        ForEach(detected, id: \.path) { socket in
                            Button(socket.name) {
                                draft.address = socket.path
                                if draft.name.isEmpty { draft.name = socket.name }
                                testResult = nil
                            }
                            .controlSize(.small)
                            .help(socket.path)
                        }
                    }
                }
            }
            Text("Another Docker engine on this Mac — Colima, OrbStack, Docker Desktop.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Test

    private var currentValidationError: String? {
        var candidate = draft
        candidate.port = parsedPort
        _ = certRevision
        return candidate.validationError()
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            testResultRow
            if case .offline(let reason)? = testResult,
               let hint = EnvironmentTroubleshooting.hint(for: draft.kind, error: reason) {
                Label(hint, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.12)))
            }
        }
    }

    private var testResultRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("Test Connection") {
                applyPort()
                testResult = .checking
                let candidate = draft
                // TLS: Touch ID first (no-op when already unlocked).
                store.environments.unlock(candidate) { failure in
                    if let failure {
                        testResult = .offline(failure)
                    } else {
                        store.environments.check(candidate) { testResult = $0 }
                    }
                }
            }
            .disabled(currentValidationError != nil || testResult == .checking)
            Group {
                switch testResult {
                case .none:
                    Text(currentValidationError ?? "").foregroundStyle(.secondary)
                case .checking?, .unknown?:
                    Text("Connecting…").foregroundStyle(.secondary)
                case .online(let info)?:
                    Label("Docker \(info.serverVersion) · \(info.operatingSystem) · \(info.containers) containers",
                          systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .offline(let reason)?:
                    Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                case .locked?:
                    Label("Locked", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(3)
            .textSelection(.enabled)
        }
    }

    private var parsedPort: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return draft.kind == .tls ? DockerEnvironment.defaultTLSPort : nil }
        return Int(trimmed) ?? -1
    }

    private func applyPort() {
        draft.port = parsedPort
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.address = draft.address.trimmingCharacters(in: .whitespaces)
    }
}
