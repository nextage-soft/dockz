import SwiftUI

/// Multipass-style machines tab: instant Alpine VMs for k3s labs and friends.
struct MachinesListView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var manager: MachineManager
    @State private var showCreate = false
    @State private var showBuildOutput = false
    @State private var showBaseImages = false
    @State private var pendingDelete: MachineManager.Machine?

    init(store: DashboardStore) {
        self.store = store
        self.manager = store.machineManager
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showCreate) {
            CreateMachineSheet(manager: manager)
        }
        .sheet(isPresented: $showBuildOutput) {
            BuildBaseSheet(manager: manager)
        }
        .sheet(isPresented: $showBaseImages) {
            BaseImagesSheet(manager: manager, showBuildOutput: $showBuildOutput)
        }
        .sheet(isPresented: Binding(
            get: { manager.provisioningMachine != nil },
            set: { if !$0 { manager.provisioningMachine = nil } }
        )) {
            ProvisioningSheet(manager: manager)
        }
        .confirmationDialog(
            "Delete machine \"\(pendingDelete?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete — the machine's disk is removed", role: .destructive) {
                if let machine = pendingDelete { manager.delete(machine.name) }
                pendingDelete = nil
            }
        }
        .alert("Machines error", isPresented: Binding(
            get: { manager.lastError != nil },
            set: { if !$0 { manager.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manager.lastError ?? "")
        }
    }

    private var header: some View {
        HStack {
            let count = manager.machines.count
            Text("\(count) \(count == 1 ? "machine" : "machines")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showBaseImages = true
            } label: {
                Label("Base Images", systemImage: "opticaldisc")
            }
            if manager.buildingBase {
                Button { showBuildOutput = true } label: {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Building…") }
                }
            } else if manager.bases.isEmpty {
                Button {
                    showBaseImages = true
                } label: {
                    Label("Set up Base Image", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    showCreate = true
                } label: {
                    Label("New Machine", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if manager.machines.isEmpty {
            EmptyStateView(
                icon: "desktopcomputer",
                title: !manager.bases.isEmpty ? "No machines" : "Multipass-style VMs",
                hint: !manager.bases.isEmpty
                    ? "Create an instant VM — boots in seconds, perfect for k3s labs.\nMachines share one NAT network, so multi-node clusters just work."
                    : "One-time setup: build a base image (Alpine ~2 min, or download Debian/Ubuntu).\nAfter that every machine is an instant APFS clone. All ARM64.",
                actionLabel: !manager.bases.isEmpty ? "New Machine…" : (manager.buildingBase ? nil : "Set up Base Image")
            ) {
                if !manager.bases.isEmpty {
                    showCreate = true
                } else {
                    showBaseImages = true
                }
            }
        } else {
            List(manager.machines) { machine in
                machineRow(machine)
            }
            .listStyle(.inset)
        }
    }

    private func machineRow(_ machine: MachineManager.Machine) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(machine.state == .running ? .green : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(machine.name).font(.system(.body, weight: .semibold))
                    StatusChip(state: stateLabel(machine.state))
                    let meta = manager.loadMeta(name: machine.name)
                    if meta.templateKind != "none" {
                        Text(meta.templateKind)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.purple.opacity(0.16)))
                            .foregroundStyle(.purple)
                    }
                    if manager.provisioningMachine == machine.name {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack(spacing: 8) {
                    Text("\(machine.settings.cpuCount) CPU · \(machine.settings.memoryGiB) GiB · \(machine.settings.diskLimitGB) GB disk")
                    if let ip = machine.ip {
                        Text(ip)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                if FileManager.default.fileExists(atPath: manager.kubeconfigURL(for: machine.name).path) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "KUBECONFIG=\(manager.kubeconfigURL(for: machine.name).path)",
                            forType: .string
                        )
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .help("Copy KUBECONFIG=… (paste in terminal to use kubectl)")
                }
                switch machine.state {
                case .running:
                    Button {
                        if let command = manager.sshCommand(for: machine.name) {
                            TerminalLauncher.launch(command)
                        }
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .help("Open terminal (SSH)")
                    .disabled(machine.ip == nil)
                    Button { manager.stop(machine.name) } label: { Image(systemName: "stop.fill") }
                        .help("Stop")
                case .starting, .stopping:
                    ProgressView().controlSize(.small)
                default:
                    Button { manager.start(machine.name) } label: { Image(systemName: "play.fill") }
                        .help("Start")
                }
                Button { pendingDelete = machine } label: { Image(systemName: "trash") }
                    .help("Delete…")
                    .disabled(machine.state == .starting || machine.state == .stopping)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func stateLabel(_ state: VMState) -> String {
        switch state {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .stopping: return "stopping"
        case .failed: return "failed"
        }
    }
}

private struct CreateMachineSheet: View {
    @ObservedObject var manager: MachineManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseID = ""
    @State private var cpus = 1.0
    @State private var memoryGiB = 1.0
    @State private var diskGB = 16.0
    @State private var mode = "none"        // none | cluster | custom
    @State private var engine = ClusterEngine.k3s
    @State private var role = ClusterRole.master
    @State private var serverName = ""
    @State private var customScript = "#!/bin/sh\nset -e\n# runs as root over SSH on first boot\n"

    private var distro: MachineDistro? { MachineDistro.by(id: baseID) }
    private var availableEngines: [ClusterEngine] { distro?.supportedEngines ?? [] }
    private var runningMachines: [String] {
        manager.machines.filter { $0.state == .running }.map(\.name)
    }

    private var currentTemplate: MachineTemplate {
        switch mode {
        case "cluster": return .cluster(engine: engine, role: role, serverName: role == .node ? serverName : nil)
        case "custom": return .custom(script: customScript)
        default: return .none
        }
    }

    private var minSpec: MinimumSpec { MinimumSpec.forTemplate(currentTemplate) }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("New Machine").font(.headline); Spacer() }
                .padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    LabeledField("Name", required: true) {
                        TextField("", text: $name, prompt: Text("k3s-master"))
                    }
                    LabeledField("Base image") {
                        Picker("", selection: $baseID) {
                            ForEach(manager.bases) { base in
                                Text("\(base.displayName) · \(base.arch)").tag(base.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: baseID) { _ in
                            if mode == "cluster", !availableEngines.contains(engine) {
                                if let first = availableEngines.first { engine = first } else { mode = "none" }
                            }
                            enforceMinimum()
                        }
                    }

                    Divider()
                    // Template — None is the default & recommended.
                    LabeledField("Template") {
                        Picker("", selection: $mode) {
                            Text("None — plain VM (recommended)").tag("none")
                            if !availableEngines.isEmpty { Text("Kubernetes cluster").tag("cluster") }
                            Text("Custom script").tag("custom")
                        }
                        .labelsHidden()
                        .onChange(of: mode) { _ in enforceMinimum() }
                    }
                    if mode == "none" {
                        Text("A clean machine — nothing installed. Perfect for experimenting; you can always install things later via the terminal.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if mode == "cluster" {
                        LabeledField("Engine") {
                            Picker("", selection: $engine) {
                                ForEach(availableEngines, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: engine) { _ in enforceMinimum() }
                        }
                        LabeledField("Role") {
                            Picker("", selection: $role) {
                                ForEach(ClusterRole.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .onChange(of: role) { _ in enforceMinimum() }
                        }
                        if role == .master {
                            Text("Master installs the control-plane and pulls the kubeconfig back to the host so you can kubectl from macOS. Needs ≥ \(minSpec.cpus) CPU / \(minSpec.memoryGiB) GiB.")
                                .font(.caption).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            LabeledField("Join master") {
                                Picker("", selection: $serverName) {
                                    Text("— pick a running master —").tag("")
                                    ForEach(masterMachines, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                            }
                            Text("Joins the selected master's cluster automatically using its saved token.")
                                .font(.caption).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if mode == "custom" {
                        TextEditor(text: $customScript)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 90)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    }

                    Divider()
                    resourceSliders
                    Text("ARM64 · root SSH with the DockZ machines key · home folder shared inside the VM")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create & Start") {
                    manager.create(name: name, cpus: Int(cpus), memoryGiB: UInt64(memoryGiB),
                                   diskGB: Int(diskGB), baseID: baseID, template: currentTemplate)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || baseID.isEmpty
                          || (mode == "cluster" && role == .node && serverName.isEmpty))
            }
            .padding(14)
        }
        .frame(width: 540, height: 640)
        .onAppear {
            if baseID.isEmpty { baseID = manager.bases.first?.id ?? "" }
            enforceMinimum()
        }
    }

    private var masterMachines: [String] {
        // Running machines whose meta marks them as a master of the chosen engine.
        runningMachines.filter { manager.loadMeta(name: $0).role == "master" }
    }

    @ViewBuilder
    private var resourceSliders: some View {
        let maxCPU = Double(ProcessInfo.processInfo.processorCount)
        LabeledField("CPUs") {
            HStack {
                Slider(value: $cpus, in: Double(minSpec.cpus)...maxCPU, step: 1)
                Text("\(Int(cpus))").frame(width: 26)
            }
        }
        LabeledField("Memory") {
            HStack {
                Slider(value: $memoryGiB, in: Double(minSpec.memoryGiB)...16, step: 1)
                Text("\(Int(memoryGiB))G").frame(width: 30)
            }
        }
        LabeledField("Disk") {
            HStack {
                Slider(value: $diskGB, in: 8...128, step: 8)
                Text("\(Int(diskGB))G").frame(width: 36)
            }
        }
        if minSpec.cpus > 1 || minSpec.memoryGiB > 1 {
            Text("Minimum for this template: \(minSpec.cpus) CPU / \(minSpec.memoryGiB) GiB — raised automatically.")
                .font(.caption).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Bumps the CPU/RAM up to the template's minimum when it exceeds current.
    private func enforceMinimum() {
        let spec = minSpec
        if cpus < Double(spec.cpus) { cpus = Double(spec.cpus) }
        if memoryGiB < Double(spec.memoryGiB) { memoryGiB = Double(spec.memoryGiB) }
    }
}

private struct ProvisioningSheet: View {
    @ObservedObject var manager: MachineManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Provisioning \(manager.provisioningMachine ?? "")", systemImage: "gearshape.2")
                    .font(.headline)
                Spacer()
                ProgressView().controlSize(.small)
                Button("Run in background") { dismiss() }
            }
            .padding(12)
            Divider()
            TerminalTextView(text: manager.provisioningLog)
        }
        .frame(width: 720, height: 460)
    }
}

private struct BaseImagesSheet: View {
    @ObservedObject var manager: MachineManager
    @Binding var showBuildOutput: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Base Images", systemImage: "opticaldisc").font(.headline)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            List {
                Section("Alpine — built locally (k3s templates verified)") {
                    ForEach(MachineDistro.catalog.filter { $0.family == "alpine" }) { row($0) }
                }
                Section("Debian / Ubuntu — downloaded cloud image (ARM64, custom script only)") {
                    ForEach(MachineDistro.catalog.filter { $0.family != "alpine" }) { row($0) }
                }
            }
            .listStyle(.inset)
            if manager.buildingBase {
                Divider()
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Preparing base image…").font(.caption)
                    Spacer()
                    Button("Show log") { showBuildOutput = true }
                }
                .padding(10)
            }
        }
        .frame(width: 560, height: 480)
    }

    private func row(_ distro: MachineDistro) -> some View {
        let built = manager.hasBase(distro.id)
        return HStack(spacing: 10) {
            Image(systemName: built ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(built ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(distro.displayName).font(.system(.body, weight: .medium))
                Text("arm64\(distro.isCloudImage ? " · cloud image" : " · netboot build")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if built {
                Button(role: .destructive) {
                    manager.deleteBase(distro.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove base image")
            } else {
                Button(distro.isCloudImage ? "Download" : "Build") {
                    showBuildOutput = true
                    manager.buildBase(distro: distro)
                }
                .disabled(manager.buildingBase)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct BuildBaseSheet: View {
    @ObservedObject var manager: MachineManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Base template build", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                Spacer()
                if manager.buildingBase { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            TerminalTextView(text: manager.buildOutput)
        }
        .frame(width: 680, height: 380)
    }
}
