import SwiftUI

/// "Advanced" card of the run/edit container form: the deep settings people
/// otherwise need `docker run` flags for, grouped and collapsed by default so
/// the common path stays short.
struct AdvancedSettingsCard: View {
    @Binding var settings: AdvancedContainerSettings

    var body: some View {
        FormSectionCard(title: "Advanced", icon: "gearshape.2") {
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup("Network identity") { networkGroup.padding(.top, 6) }
                DisclosureGroup("Health check") { healthGroup.padding(.top, 6) }
                DisclosureGroup(capabilitiesTitle) { capabilitiesGroup.padding(.top, 6) }
                DisclosureGroup("Runtime & devices") { runtimeGroup.padding(.top, 6) }
                DisclosureGroup("Logging") { loggingGroup.padding(.top, 6) }
            }
        }
    }

    // MARK: - Groups

    private var networkGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledField("Hostname") {
                TextField("", text: $settings.hostname, prompt: Text("docker default (container id)"))
            }
            LabeledField("DNS") {
                LineListEditor(text: $settings.dnsText, placeholder: "1.1.1.1", addLabel: "Add DNS server")
            }
            LabeledField("Extra hosts") {
                KeyValueListEditor(keyPlaceholder: "host.local", valuePlaceholder: "10.0.0.5",
                                   addLabel: "Add host entry", text: $settings.extraHostsText)
            }
        }
    }

    private var healthGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledField("") {
                Toggle("Disable health check (overrides the image's)", isOn: $settings.healthDisabled)
            }
            if !settings.healthDisabled {
                LabeledField("Command") {
                    TextField("", text: $settings.healthCommand,
                              prompt: Text("curl -fs http://localhost/health || exit 1"))
                        .font(.system(size: 12, design: .monospaced))
                }
                LabeledField("Timing") {
                    HStack(spacing: 6) {
                        secondsField("interval", $settings.healthIntervalSeconds)
                        secondsField("timeout", $settings.healthTimeoutSeconds)
                        secondsField("start", $settings.healthStartPeriodSeconds)
                        TextField("", text: $settings.healthRetries, prompt: Text("retries"))
                            .frame(width: 70)
                    }
                }
                Text("Empty command keeps the image's own health check. Times in seconds.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var capabilitiesTitle: String {
        let count = settings.capAdd.count + settings.capDrop.count
        return count > 0 ? "Capabilities (\(count) changed)" : "Capabilities"
    }

    private var capabilitiesGroup: some View {
        let choices = ContainerConfigBuilder.capabilityChoices(including: settings.capAdd + settings.capDrop)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Capability").frame(maxWidth: .infinity, alignment: .leading)
                Text("Add").frame(width: 44)
                Text("Drop").frame(width: 44)
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(choices, id: \.self) { capability in
                HStack {
                    Text(capability)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("", isOn: membership(capability, in: \.capAdd, exclusiveWith: \.capDrop))
                        .labelsHidden().toggleStyle(.checkbox).frame(width: 44)
                    Toggle("", isOn: membership(capability, in: \.capDrop, exclusiveWith: \.capAdd))
                        .labelsHidden().toggleStyle(.checkbox).frame(width: 44)
                }
            }
        }
    }

    private var runtimeGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledField("") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Run an init process (reaps zombies, forwards signals)", isOn: $settings.initProcess)
                    Toggle("Read-only root filesystem", isOn: $settings.readonlyRootfs)
                }
            }
            LabeledField("Shared mem") {
                mebibyteField($settings.shmSizeMiB, prompt: "64 (default)")
            }
            LabeledField("Mem reserve") {
                mebibyteField($settings.memoryReservationMiB, prompt: "none")
            }
            LabeledField("Devices") {
                LineListEditor(text: $settings.devicesText, placeholder: "/dev/fuse  or  /dev/sda:/dev/xvda:rwm",
                               addLabel: "Add device")
            }
            LabeledField("Sysctls") {
                KeyValueListEditor(keyPlaceholder: "net.core.somaxconn", valuePlaceholder: "1024",
                                   addLabel: "Add sysctl", text: $settings.sysctlsText)
            }
        }
    }

    private var loggingGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledField("Driver") {
                Picker("", selection: $settings.logDriver) {
                    Text("daemon default").tag("")
                    ForEach(logDriverChoices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
            }
            if !settings.logDriver.isEmpty {
                LabeledField("Options") {
                    KeyValueListEditor(keyPlaceholder: "max-size", valuePlaceholder: "10m",
                                       addLabel: "Add option", text: $settings.logOptsText)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Keeps a driver already set on the container selectable even if it is
    /// not in the common list.
    private var logDriverChoices: [String] {
        let known = ContainerConfigBuilder.logDrivers
        return settings.logDriver.isEmpty || known.contains(settings.logDriver)
            ? known : known + [settings.logDriver]
    }

    /// A capability can't be both added and dropped; ticking one side clears
    /// the other.
    private func membership(_ capability: String,
                            in list: WritableKeyPath<AdvancedContainerSettings, [String]>,
                            exclusiveWith other: WritableKeyPath<AdvancedContainerSettings, [String]>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: list].contains(capability) },
            set: { isOn in
                if isOn {
                    if !settings[keyPath: list].contains(capability) { settings[keyPath: list].append(capability) }
                    settings[keyPath: other].removeAll { $0 == capability }
                } else {
                    settings[keyPath: list].removeAll { $0 == capability }
                }
            }
        )
    }

    private func secondsField(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text("\(prompt) s")).frame(width: 78)
    }

    private func mebibyteField(_ text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 6) {
            TextField("", text: text, prompt: Text(prompt)).frame(width: 110)
            Text("MiB").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One-value-per-row editor that serializes to the form's newline format.
struct LineListEditor: View {
    struct Row: Identifiable {
        let id = UUID()
        var value = ""
    }

    @Binding var text: String
    let placeholder: String
    var addLabel = "Add"
    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    TextField("", text: $row.value, prompt: Text(placeholder))
                        .font(.system(size: 12, design: .monospaced))
                    RemoveRowButton { rows.removeAll { $0.id == row.id } }
                }
            }
            AddRowButton(title: addLabel) { rows.append(Row()) }
        }
        .onAppear {
            guard rows.isEmpty else { return }
            rows = text.split(separator: "\n").map { Row(value: String($0)) }
        }
        .onChange(of: rows.map(\.value)) { values in
            text = values.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }
}
