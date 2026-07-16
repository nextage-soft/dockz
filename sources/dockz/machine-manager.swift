import AppKit
import Foundation

/// Multipass-style lightweight VMs, fully independent of the docker engine
/// VM. A machine is a directory under ~/.dockz/machines/<name>/ whose disk is
/// an APFS clone of a shared Alpine base template — creation is near-instant
/// and each idle machine costs a few tens of MB.
@MainActor
final class MachineManager: ObservableObject {
    struct Machine: Identifiable {
        let name: String
        var state: VMState = .stopped
        var ip: String?
        var settings: DockzSettings

        var id: String { name }
    }

    @Published var machines: [Machine] = []
    @Published var baseImageReady = false
    @Published var buildingBase = false
    @Published var buildOutput = ""
    @Published var lastError: String?
    // Template provisioning (see machine-provisioning.swift).
    @Published var provisioningMachine: String?
    @Published var provisioningLog = ""
    // Base image catalog (see machine-bases.swift).
    @Published var bases: [MachineBase] = []

    private var controllers: [String: VMController] = [:]
    // Internal (not private) so the provisioning extension in another file can reach them.
    let machinesDirectory = DockzPaths().baseDirectory.appendingPathComponent("machines", isDirectory: true)
    var machinesDir: URL { machinesDirectory }
    var basesDir: URL { machinesDirectory.appendingPathComponent("bases", isDirectory: true) }
    private var baseImageURL: URL { MachineSSHKey.baseImageURL }
    private var sshKeyURL: URL { MachineSSHKey.privateKeyURL }
    var sshKeyPath: String { sshKeyURL.path }
    var machineSSHPublicKey: String? { MachineSSHKey.ensure() }
    private var provisionedThisBoot: Set<String> = []

    init() {
        try? FileManager.default.createDirectory(at: machinesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: basesDir, withIntermediateDirectories: true)
        loadBases()
        baseImageReady = !bases.isEmpty
        scan()
    }

    // MARK: - Inventory

    func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: machinesDirectory.path)) ?? []
        var updated: [Machine] = []
        for name in names.sorted() {
            guard !name.hasPrefix("."), !name.hasPrefix("id_ed25519") else { continue }
            let directory = machinesDirectory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let paths = DockzPaths(baseDirectory: directory)
            var machine = Machine(name: name, settings: DockzSettings.load(from: paths))
            if let existing = machines.first(where: { $0.name == name }) {
                machine.state = existing.state
                machine.ip = existing.ip
            }
            updated.append(machine)
        }
        machines = updated
    }

    private func directory(for name: String) -> URL {
        machinesDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private func updateMachine(_ name: String, _ mutate: (inout Machine) -> Void) {
        guard let index = machines.firstIndex(where: { $0.name == name }) else { return }
        mutate(&machines[index])
    }

    // MARK: - Base template

    func ensureSSHKey() -> String? {
        MachineSSHKey.ensure()
    }

    /// Builds the shared Alpine base template (one time, ~2 minutes).
    func buildBaseImage() {
        guard !buildingBase else { return }
        guard let publicKey = ensureSSHKey() else {
            lastError = "Could not create the machines SSH key"
            return
        }
        buildingBase = true
        buildOutput = "Building the Alpine base template (one time)…\n"
        let request = ImageBuilderCLI.BuildRequest(
            outputURL: baseImageURL,
            sizeGB: 4,
            profile: "machine",
            publicKey: publicKey,
            progress: { [weak self] line in
                DispatchQueue.main.async { self?.buildOutput += line + "\n" }
            }
        )
        Thread.detachNewThread { [weak self] in
            do {
                try ImageBuilderCLI.buildDiskImage(request)
                DispatchQueue.main.async {
                    self?.buildingBase = false
                    self?.baseImageReady = true
                    self?.buildOutput += "✓ base template ready — machines now create instantly\n"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.buildingBase = false
                    self?.buildOutput += "✗ build failed: \(error.localizedDescription)\n"
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Lifecycle

    func create(name: String, cpus: Int, memoryGiB: UInt64, diskGB: Int, baseID: String, template: MachineTemplate = .none) {
        let sanitized = name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !sanitized.isEmpty else {
            lastError = "Machine name must contain letters/numbers"
            return
        }
        guard hasBase(baseID) else {
            lastError = "Build the \(baseID) base image first"
            return
        }
        let distro = MachineDistro.by(id: baseID)
        let directory = directory(for: sanitized)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            lastError = "Machine \"\(sanitized)\" already exists"
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // APFS clone of the chosen base — instant, copy-on-write.
            let clone = Process()
            clone.executableURL = URL(fileURLWithPath: "/bin/cp")
            clone.arguments = ["-c", baseImagePath(baseID).path, directory.appendingPathComponent("disk.img").path]
            try clone.run()
            clone.waitUntilExit()
            guard clone.terminationStatus == 0 else {
                throw DockzError.socketSetupFailed("APFS clone failed")
            }
            let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("disk.img"))
            try handle.truncate(atOffset: UInt64(max(diskGB, 4)) * 1024 * 1024 * 1024)
            try handle.close()

            // Cloud images (Debian/Ubuntu) get a cloud-init seed for SSH key + hostname.
            if distro?.isCloudImage == true {
                guard let publicKey = machineSSHPublicKey else {
                    throw DockzError.socketSetupFailed("no SSH key")
                }
                try CloudInitSeed.makeSeedISO(
                    at: DockzPaths(baseDirectory: directory).seedISO,
                    hostname: sanitized,
                    publicKey: publicKey
                )
            }

            var settings = DockzSettings()
            settings.cpuCount = cpus
            settings.memoryGiB = memoryGiB
            settings.diskLimitGB = diskGB
            settings.enableRosetta = false
            settings.save(to: DockzPaths(baseDirectory: directory))
            var meta = MachineMeta.from(template)
            meta.distroID = baseID
            saveMeta(name: sanitized, meta)
        } catch {
            lastError = "Create failed: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: directory)
            return
        }
        scan()
        start(sanitized)
    }

    func start(_ name: String) {
        guard controllers[name] == nil else { return }
        let paths = DockzPaths(baseDirectory: directory(for: name))
        let settings = DockzSettings.load(from: paths)
        let controller = VMController(paths: paths, settings: settings)
        controllers[name] = controller
        controller.onStateChange = { [weak self] state in
            guard let self else { return }
            self.updateMachine(name) { $0.state = state }
            switch state {
            case .running:
                self.afterBoot(name)
            case .stopped, .failed:
                self.controllers.removeValue(forKey: name)
                self.provisionedThisBoot.remove(name)
                self.updateMachine(name) { $0.ip = nil }
            default:
                break
            }
        }
        controller.start()
    }

    func stop(_ name: String) {
        controllers[name]?.stop()
    }

    func delete(_ name: String) {
        let finish = { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.directory(for: name))
            self.scan()
        }
        if let controller = controllers[name] {
            controller.stop { finish() }
        } else {
            finish()
        }
    }

    /// Builds an SSH command for the embedded terminal (nil if not booted yet).
    func sshCommand(for name: String) -> TerminalCommand? {
        guard let ip = machines.first(where: { $0.name == name })?.ip else {
            lastError = "No IP yet — wait for the machine to finish booting"
            return nil
        }
        return TerminalCommand(
            title: name,
            subtitle: "ssh root@\(ip)",
            executable: "/usr/bin/ssh",
            arguments: [
                "-i", sshKeyURL.path,
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR",
                "root@\(ip)",
            ]
        )
    }

    /// Stops every running machine (app quit). Completion fires on main.
    func stopAll(completion: @escaping () -> Void) {
        let running = controllers.values
        guard !running.isEmpty else {
            completion()
            return
        }
        let group = DispatchGroup()
        for controller in running {
            group.enter()
            controller.stop { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    // MARK: - Post-boot (IP + hostname)

    private func afterBoot(_ name: String) {
        let meta = loadMeta(name: name)
        if meta.isCloudImage {
            resolveCloudIP(name)
        } else {
            resolveVsockIP(name)
        }
    }

    /// Alpine (netboot) machines report their IP over vsock and accept a
    /// hostname command through the debug shell.
    private func resolveVsockIP(_ name: String, attempt: Int = 0) {
        guard let controller = controllers[name] else { return }
        GuestIPResolver.fetch(connect: controller.vsockConnector()) { [weak self] ip in
            DispatchQueue.main.async {
                guard let self else { return }
                if let ip {
                    self.updateMachine(name) { $0.ip = ip }
                    GuestShellRunner.run(
                        script: "hostname \(name); echo \(name) > /etc/hostname",
                        connect: controller.vsockConnector()
                    ) { _ in }
                    self.onIPReady(name, ip: ip)
                } else if attempt < 15, self.controllers[name] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.resolveVsockIP(name, attempt: attempt + 1)
                    }
                }
            }
        }
    }

    /// Cloud images (Debian/Ubuntu) have no vsock agent; learn their IP from
    /// the macOS vmnet DHCP lease keyed by the machine's MAC.
    private func resolveCloudIP(_ name: String) {
        let macFile = DockzPaths(baseDirectory: directory(for: name)).macAddressFile
        guard let mac = try? String(contentsOf: macFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !mac.isEmpty else { return }
        DHCPLeaseResolver.waitForIP(mac: mac) { [weak self] ip in
            DispatchQueue.main.async {
                guard let self, let ip, self.controllers[name] != nil else { return }
                self.updateMachine(name) { $0.ip = ip }
                self.onIPReady(name, ip: ip)
            }
        }
    }

    private func onIPReady(_ name: String, ip: String) {
        // Apply the machine's template once per boot (SSH-driven; works on any distro).
        if !provisionedThisBoot.contains(name) {
            provisionedThisBoot.insert(name)
            applyTemplateIfNeeded(name: name, ip: ip)
        }
    }
}
