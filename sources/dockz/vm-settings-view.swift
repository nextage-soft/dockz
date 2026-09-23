import SwiftUI
import Virtualization

/// VM resource settings — edits ~/.dockz/config.json and restarts the VM.
struct VMSettingsView: View {
    @ObservedObject var store: DashboardStore
    @State private var cpuCount = 4.0
    @State private var memoryGiB = 4.0
    @State private var diskLimitGB = 64.0
    @State private var shareHome = true
    @State private var enableRosetta = true
    @State private var loaded = false
    @State private var snapshotName = ""
    @State private var snapshotRefresh = 0
    @State private var pendingRestore: DiskSnapshot?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @State private var showCleanup = false

    private var hardwareCPUs: Int { ProcessInfo.processInfo.processorCount }

    /// Slider ceiling for VM memory. Bounded by physical RAM (a fixed 16 GiB
    /// cap both starved big Macs and let small Macs pick more than they have —
    /// VZ then clamped silently and the VM got less than the UI claimed).
    private var hardwareMemoryGiB: Int {
        let physical = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let vzMax = Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / (1024 * 1024 * 1024))
        return max(2, min(physical, vzMax))
    }

    var body: some View {
        Form {
            aboutSection
            Section {
                baseSystemRow("OS", key: "os", icon: "cpu")
                baseSystemRow("Kernel", key: "kernel", icon: "gearshape.2")
                baseSystemRow("Docker Engine", key: "docker", icon: "shippingbox")
                baseSystemRow("containerd", key: "containerd", icon: "cube")
                baseSystemRow("Disk", key: "disk", icon: "internaldrive")
                baseSystemRow("Memory", key: "memory", icon: "memorychip")
                baseSystemRow("Uptime", key: "uptime", icon: "clock")
            } header: {
                HStack {
                    Text("Base system (live from the VM)")
                    Spacer()
                    Button {
                        store.loadBaseSystemInfo()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Reload")
                }
            }
            Section("Virtual machine resources") {
                VStack(alignment: .leading) {
                    Slider(value: $cpuCount, in: 1...Double(hardwareCPUs), step: 1) {
                        Text("CPUs")
                    }
                    Text("\(Int(cpuCount)) of \(hardwareCPUs) cores")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Slider(value: $memoryGiB, in: 2...Double(hardwareMemoryGiB), step: 1) {
                        Text("Memory")
                    }
                    Text("\(Int(memoryGiB)) of \(hardwareMemoryGiB) GiB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Slider(value: $diskLimitGB, in: 16...256, step: 8) {
                        Text("Disk limit")
                    }
                    Text("\(Int(diskLimitGB)) GB — growing applies on restart")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // A limit below the current disk size cannot take effect —
                    // ext4 can't be shrunk in place. Say so instead of silently
                    // ignoring the setting (that silence read as "bug" before).
                    if let apparent = DiskUsage.apparentBytes(at: DockzPaths().diskImage),
                       UInt64(diskLimitGB) * 1_073_741_824 < apparent {
                        Label("The disk is already \(DiskUsage.format(apparent)) — the limit can only grow it. Shrinking requires rebuilding the VM disk (wipes all docker data); reclaim free space below instead.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            diskSpaceSection
            Section("Integration") {
                Toggle("Share home directory (virtiofs bind mounts)", isOn: $shareHome)
                Toggle("Rosetta (run linux/amd64 images)", isOn: $enableRosetta)
                TimeZoneSettingRow(store: store)
                Toggle("Start DockZ at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            try LaunchAtLogin.set(enabled)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                } else if launchAtLogin {
                    Text("The Docker engine comes up in the background — no window opens. Manage it in System Settings → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            DockerCLISettingsSection(store: store)
            Section {
                HStack {
                    Text("VM: \(store.vmDisplayState)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply & Restart VM") { apply() }
                        .keyboardShortcut(.defaultAction)
                }
                Text("Changes take effect after the VM restarts. Running containers will stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                let snapshots = snapshotRefresh >= 0 ? (store.hostActions?.snapshots() ?? []) : []
                HStack {
                    TextField("Snapshot name", text: $snapshotName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Button("Create Snapshot") {
                        store.hostActions?.createSnapshot(snapshotName)
                        snapshotName = ""
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { snapshotRefresh += 1 }
                    }
                    Spacer()
                }
                if snapshots.isEmpty {
                    Text("No snapshots yet. A snapshot is an instant copy of the VM disk you can roll back to.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(snapshots) { snap in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snap.name).font(.callout)
                                Text(snap.createdAt).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { pendingRestore = snap }
                                .controlSize(.small)
                            Button {
                                store.hostActions?.deleteSnapshot(snap.id)
                                snapshotRefresh += 1
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Text("Creating or restoring briefly stops the VM (disk is cloned via APFS — instant).")
                    .font(.caption).foregroundStyle(.tertiary)
            } header: {
                Text("VM snapshots")
            }
            Section {
                LabeledContent("Data folder") {
                    Text(store.hostActions?.storagePath() ?? "~/.dockz")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Change Folder…") { chooseStorageFolder() }
                    if (store.hostActions?.storagePath() ?? "").hasSuffix("dockz-data") {
                        Button("Reset to Default") { store.hostActions?.resetStorage() }
                    }
                    Spacer()
                }
                Text("Moving data (disk images, machines) stops the VM and quits DockZ; reopen it afterwards. Good for putting large disks on an external SSD.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Storage location")
            }
            Section("Files") {
                LabeledContent("Docker socket", value: "docker.sock (in data folder)")
                LabeledContent("VM disk", value: "disk.img (sparse, in data folder)")
                LabeledContent("Console log", value: "console.log (in data folder)")
                LabeledContent("Machines", value: "machines/ (in data folder)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showCleanup) {
            CleanupSheetView(store: store)
        }
        .confirmationDialog(
            "Restore snapshot \"\(pendingRestore?.name ?? "")\"?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restore — current VM disk is replaced", role: .destructive) {
                if let snap = pendingRestore { store.hostActions?.restoreSnapshot(snap.id) }
                pendingRestore = nil
            }
        } message: {
            Text("The VM stops, its disk is rolled back to this snapshot, then restarts. Unsaved changes since the snapshot are lost.")
        }
        .onAppear {
            loadCurrent()
            if store.baseSystem.isEmpty { store.loadBaseSystemInfo() }
        }
    }

    // MARK: - Disk space

    /// Shows what disk.img really costs the Mac and reclaims space freed
    /// inside the VM (docker prune leaves the sparse file fully allocated
    /// until the guest TRIMs — fstrim over vsock, no restart needed).
    private var diskSpaceSection: some View {
        Section {
            LabeledContent("On your Mac") {
                Text(DiskUsage.summary(for: DockzPaths().diskImage) ?? "—")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    store.reclaimDiskSpace()
                } label: {
                    if store.reclaimBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reclaiming…")
                        }
                    } else {
                        Label("Reclaim Free Space", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
                .disabled(store.reclaimBusy || !store.engineReady)
                Button {
                    showCleanup = true
                } label: {
                    Label("Clean Up…", systemImage: "paintbrush")
                }
                .disabled(!store.engineReady)
                Spacer()
            }
            if !store.reclaimResult.isEmpty {
                Text(store.reclaimResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Space freed inside the VM (removed images, pruned build cache) is returned to your Mac. Tip: prune unused images first, then reclaim.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } header: {
            Text("Disk space")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(AppInfo.name).font(.title3.weight(.semibold))
                        Text("v\(AppInfo.versionLong)")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                            .textSelection(.enabled)
                    }
                    Text(AppInfo.tagline)
                        .font(.callout).foregroundStyle(.secondary)
                    Text(AppInfo.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)

            LabeledContent("Version") {
                Text(AppInfo.versionLong).font(.callout.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Requires", value: "macOS \(AppInfo.minimumSystem)+ · Apple Silicon")
            LabeledContent("Running on", value: AppInfo.runningOS)
            LabeledContent("License", value: AppInfo.license)
            LabeledContent("Copyright", value: AppInfo.copyright)
            HStack {
                Link(destination: URL(string: AppInfo.homepage)!) {
                    Label("Project homepage", systemImage: "safari")
                }
                Spacer()
                Button {
                    let text = "\(AppInfo.name) \(AppInfo.versionLong)\n\(AppInfo.homepage)\n\(AppInfo.runningOS)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy version info", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("About")
        }
    }

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to hold DockZ data (a 'dockz-data' subfolder is created)"
        panel.prompt = "Move Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.hostActions?.changeStorage(url)
    }

    private func baseSystemRow(_ label: String, key: String, icon: String) -> some View {
        LabeledContent {
            Text(store.baseSystem[key] ?? (store.engineReady ? "…" : "—"))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } label: {
            Label(label, systemImage: icon)
        }
    }

    private func loadCurrent() {
        guard !loaded, let settings = store.hostActions?.currentSettings() else { return }
        loaded = true
        cpuCount = Double(settings.cpuCount)
        memoryGiB = Double(settings.memoryGiB)
        diskLimitGB = Double(settings.diskLimitGB)
        shareHome = settings.shareHomeDirectory
        enableRosetta = settings.enableRosetta
    }

    private func apply() {
        var settings = store.hostActions?.currentSettings() ?? DockzSettings()
        settings.cpuCount = Int(cpuCount)
        settings.memoryGiB = UInt64(memoryGiB)
        settings.diskLimitGB = Int(diskLimitGB)
        settings.shareHomeDirectory = shareHome
        settings.enableRosetta = enableRosetta
        store.hostActions?.restartVM(settings)
    }
}
