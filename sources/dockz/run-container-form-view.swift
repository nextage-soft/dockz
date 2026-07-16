import SwiftUI

/// Portainer-style container config form — used both to run a new container
/// and to edit an existing one (edit = validate-create + replace + rename).
/// Custom card layout (no grouped Form): predictable leading-aligned fields.
struct RunContainerFormView: View {
    enum Mode {
        case run
        case edit(DashboardStore.EditContainerPayload)

        var title: String {
            if case .edit = self { return "Edit Container" }
            return "Run Container"
        }

        var subtitle: String {
            if case .edit(let payload) = self { return "Recreates \(payload.originalName) with the new configuration" }
            return "The image is pulled automatically if missing"
        }

        var applyLabel: String {
            if case .edit = self { return "Apply & Recreate" }
            return "Run"
        }
    }

    @ObservedObject var store: DashboardStore
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var form: RunContainerForm

    init(store: DashboardStore, mode: Mode) {
        self.store = store
        self.mode = mode
        if case .edit(let payload) = mode {
            _form = State(initialValue: payload.form)
        } else {
            _form = State(initialValue: RunContainerForm())
        }
    }

    private var isBusy: Bool {
        store.busyIDs.contains("run-container") || store.busyIDs.contains("edit-container")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    identityCard
                    FormSectionCard(title: "Port mappings", icon: "network") {
                        PortMappingListEditor(text: $form.portsText)
                    }
                    FormSectionCard(title: "Environment variables", icon: "list.bullet.rectangle") {
                        KeyValueListEditor(keyPlaceholder: "KEY", valuePlaceholder: "value", text: $form.envText)
                    }
                    FormSectionCard(title: "Volumes", icon: "externaldrive") {
                        VolumeMappingListEditor(text: $form.volumesText)
                    }
                    FormSectionCard(title: "Labels", icon: "tag") {
                        KeyValueListEditor(keyPlaceholder: "label", valuePlaceholder: "value",
                                           addLabel: "Add label", text: $form.labelsText)
                    }
                    policyCard
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 720)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(mode.title).font(.headline)
                Text(mode.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
                Text(isEditMode ? "Recreating…" : "Creating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private var identityCard: some View {
        FormSectionCard(title: "Image & identity", icon: "shippingbox") {
            VStack(spacing: 8) {
                LabeledField("Image", required: true) {
                    TextField("", text: $form.image, prompt: Text("nginx:alpine"))
                }
                LabeledField("Name") {
                    TextField("", text: $form.name, prompt: Text("auto-generated if blank"))
                }
                LabeledField("Command") {
                    TextField("", text: $form.command, prompt: Text("image default"))
                }
                LabeledField("Entrypoint") {
                    TextField("", text: $form.entrypoint, prompt: Text("image default"))
                }
                LabeledField("User") {
                    TextField("", text: $form.user, prompt: Text("image default, e.g. 1000:1000"))
                }
                LabeledField("Working dir") {
                    TextField("", text: $form.workingDir, prompt: Text("image default"))
                }
            }
        }
    }

    private var policyCard: some View {
        FormSectionCard(title: "Policy, network & resources", icon: "slider.horizontal.3") {
            VStack(spacing: 10) {
                LabeledField("Restart") {
                    Picker("", selection: $form.restartPolicy) {
                        Text("no").tag("no")
                        Text("always").tag("always")
                        Text("unless-stopped").tag("unless-stopped")
                        Text("on-failure").tag("on-failure")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                LabeledField("Network") {
                    Picker("", selection: $form.network) {
                        Text("default (bridge)").tag("")
                        ForEach(store.networks.filter { !["host", "none"].contains($0.name) }) { network in
                            Text(network.name).tag(network.name)
                        }
                        if !form.network.isEmpty && !store.networks.contains(where: { $0.name == form.network }) {
                            Text(form.network).tag(form.network)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }
                LabeledField("Memory") {
                    HStack(spacing: 6) {
                        TextField("", text: $form.memoryMiB, prompt: Text("unlimited"))
                            .frame(width: 110)
                        Text("MiB").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledField("CPUs") {
                    HStack(spacing: 6) {
                        TextField("", text: $form.cpus, prompt: Text("unlimited"))
                            .frame(width: 110)
                        Text("cores").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledField("") {
                    Toggle("Privileged mode", isOn: $form.privileged)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var footer: some View {
        HStack {
            if isEditMode {
                Label("Recreates the container — data outside volumes is lost.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Volume paths under \(NSHomeDirectory()) are shared with the VM.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button(mode.applyLabel) { apply() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(form.image.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
        }
        .padding(14)
    }

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func apply() {
        switch mode {
        case .run:
            store.runContainer(form) { success in
                if success { dismiss() }
            }
        case .edit(let payload):
            store.applyEditedContainer(payload, form: form) { success in
                if success { dismiss() }
            }
        }
    }
}

// MARK: - Layout building blocks

/// Rounded "card" with a small icon+title header.
struct FormSectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }
}

/// Fixed-width trailing label + leading-aligned control, columns line up.
struct LabeledField<Content: View>: View {
    let label: String
    var required = false
    @ViewBuilder let content: Content

    init(_ label: String, required: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.required = required
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 2) {
                Text(label)
                if required { Text("*").foregroundStyle(.red) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 92, alignment: .trailing)
            content
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
