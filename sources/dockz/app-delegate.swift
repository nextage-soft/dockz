import AppKit
import Virtualization

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = DockzPaths()
    private var settings = DockzSettings()
    private var menuController: StatusMenuController?
    private var vmController: VMController?
    private var bringup: DockerBringupCoordinator?
    private var display = StatusMenuController.DisplayState()
    private let dashboardStore = DashboardStore()
    private var dashboardController: DashboardWindowController?
    private var imageSetupController: GuestImageSetupWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? paths.ensureBaseDirectory()
        settings = DockzSettings.load(from: paths)
        configureDashboardStore()
        MainMenuBuilder.install(delegate: self)

        menuController = StatusMenuController(actions: .init(
            openDashboard: { [weak self] in self?.openDashboard() },
            startVM: { [weak self] in self?.startVM() },
            stopVM: { [weak self] in self?.vmController?.stop() },
            useDockerContext: { DockerContextInstaller.useContext() },
            openConsoleLog: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(self.paths.consoleLog)
            },
            openDataFolder: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(self.paths.baseDirectory)
            },
            quit: { NSApp.terminate(nil) }
        ))

        display.rosettaAvailable = VZLinuxRosettaDirectoryShare.availability == .installed
        display.diskImageMissing = !paths.diskImageExists
        refreshMenu()

        if paths.diskImageExists {
            startVM()
        } else {
            presentMissingDiskImageAlert()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "dockz" }) {
            openDashboard()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dockerRunning = vmController != nil && (display.vmState == .running || display.vmState == .starting)
        let machinesRunning = !dashboardStore.machineManager.machines.filter { $0.state == .running || $0.state == .starting }.isEmpty
        guard dockerRunning || machinesRunning else { return .terminateNow }

        bringup?.stop()
        bringup = nil
        let group = DispatchGroup()
        if dockerRunning, let vmController {
            group.enter()
            vmController.stop { group.leave() }
        }
        group.enter()
        dashboardStore.machineManager.stopAll { group.leave() }
        group.notify(queue: .main) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - VM lifecycle

    private func startVM() {
        display.diskImageMissing = !paths.diskImageExists
        guard !display.diskImageMissing else {
            presentMissingDiskImageAlert()
            refreshMenu()
            return
        }
        guard vmController == nil else { return }
        ensureDiskLimit()
        let controller = VMController(paths: paths, settings: settings)
        controller.onStateChange = { [weak self] state in self?.vmStateChanged(state) }
        vmController = controller
        controller.start()
    }

    private func vmStateChanged(_ state: VMState) {
        display.vmState = state
        switch state {
        case .running:
            startBringup()
        case .stopped, .failed:
            bringup?.stop()
            bringup = nil
            vmController = nil
            display.dockerReady = false
            display.guestIP = nil
            display.forwardedPorts = []
        case .starting, .stopping:
            break
        }
        refreshMenu()
    }

    private func startBringup() {
        guard let vmController else { return }
        let coordinator = DockerBringupCoordinator(vm: vmController, paths: paths)
        coordinator.onUpdate = { [weak self] in self?.bringupUpdated() }
        bringup = coordinator
        coordinator.start()
    }

    private func bringupUpdated() {
        guard let bringup else { return }
        display.dockerReady = bringup.dockerReady
        display.guestIP = bringup.guestIP
        display.forwardedPorts = bringup.forwardedPorts
        refreshMenu()
    }

    private func refreshMenu() {
        menuController?.update(display)
    }

    // MARK: - Dashboard

    private func configureDashboardStore() {
        dashboardStore.apiProvider = { [weak self] in self?.bringup?.apiClient }
        dashboardStore.shellProvider = { [weak self] in
            guard let self, self.display.vmState == .running else { return nil }
            return self.vmController?.vsockConnector()
        }
        dashboardStore.hostActions = .init(
            restartVM: { [weak self] newSettings in self?.applySettingsAndRestart(newSettings) },
            currentSettings: { [weak self] in self?.settings ?? DockzSettings() },
            startVM: { [weak self] in self?.startVM() },
            stopVM: { [weak self] in self?.vmController?.stop() },
            vmStateLabel: { [weak self] in
                guard let self else { return "?" }
                switch self.display.vmState {
                case .stopped: return "Stopped"
                case .starting: return "Starting…"
                case .running: return "Running"
                case .stopping: return "Stopping…"
                case .failed: return "Failed"
                }
            },
            storagePath: { StorageLocation.currentRoot.path },
            changeStorage: { [weak self] parent in self?.changeStorageLocation(toParent: parent) },
            resetStorage: { [weak self] in self?.changeStorageLocation(toParent: nil) },
            snapshots: { [weak self] in self.map { SnapshotStore.list($0.paths) } ?? [] },
            createSnapshot: { [weak self] name in self?.createSnapshot(named: name) },
            restoreSnapshot: { [weak self] id in self?.restoreSnapshot(id: id) },
            deleteSnapshot: { [weak self] id in
                guard let self else { return }
                SnapshotStore.delete(self.paths, id: id)
            }
        )
    }

    private func openDashboard() {
        if dashboardController == nil {
            dashboardController = DashboardWindowController(store: dashboardStore)
        }
        dashboardController?.present()
    }

    @objc func openDashboardSettings() {
        dashboardStore.requestedSection = .settings
        openDashboard()
    }

    /// Grows the sparse disk file up to the configured limit before boot; the
    /// guest's dockz-resize service then grows the partition+fs to match.
    /// Shrinking is never done here (it would corrupt the filesystem).
    private func ensureDiskLimit() {
        let limitBytes = UInt64(max(settings.diskLimitGB, 8)) * 1024 * 1024 * 1024
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: paths.diskImage.path),
              let currentSize = attributes[.size] as? UInt64,
              currentSize < limitBytes,
              let handle = try? FileHandle(forWritingTo: paths.diskImage) else { return }
        try? handle.truncate(atOffset: limitBytes)
        try? handle.close()
        NSLog("dockz: disk grown to \(settings.diskLimitGB)G (sparse)")
    }

    /// Moves the whole data directory to a new location (or back to default),
    /// then quits so everything re-resolves cleanly on next launch. Safest
    /// approach: no live re-pointing of open disk images.
    private func changeStorageLocation(toParent parent: URL?) {
        let proceed = { [weak self] in
            guard let self else { return }
            do {
                if let parent {
                    try StorageLocation.migrate(toParent: parent)
                } else {
                    try StorageLocation.resetToDefault()
                }
                let alert = NSAlert()
                alert.messageText = "Storage moved"
                alert.informativeText = "DockZ data is now at:\n\(StorageLocation.currentRoot.path)\n\nDockZ will quit now — reopen it to continue."
                alert.runModal()
                NSApp.terminate(nil)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not move storage"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
                self.startVM()
            }
        }
        // Stop machines and the docker VM before moving their disk images.
        dashboardStore.machineManager.stopAll { [weak self] in
            guard let self else { return }
            if let vmController {
                self.bringup?.stop()
                self.bringup = nil
                vmController.stop { proceed() }
            } else {
                proceed()
            }
        }
    }

    // MARK: - Snapshots (VM must be quiesced while cloning/restoring the disk)

    private func snapshotTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }

    private func createSnapshot(named name: String) {
        withStoppedVM { [weak self] in
            guard let self else { return }
            do {
                try SnapshotStore.create(self.paths, name: name,
                                         id: UUID().uuidString, timestamp: self.snapshotTimestamp())
            } catch {
                self.presentError("Snapshot failed", error.localizedDescription)
            }
        }
    }

    private func restoreSnapshot(id: String) {
        withStoppedVM { [weak self] in
            guard let self else { return }
            do {
                try SnapshotStore.restore(self.paths, id: id)
            } catch {
                self.presentError("Restore failed", error.localizedDescription)
            }
        }
    }

    /// Stops the VM, runs `work`, then restarts if it had been running.
    private func withStoppedVM(_ work: @escaping () -> Void) {
        let wasRunning = vmController != nil
        guard let vmController else {
            work()
            return
        }
        bringup?.stop()
        bringup = nil
        vmController.stop { [weak self] in
            work()
            if wasRunning { self?.startVM() }
        }
    }

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func applySettingsAndRestart(_ newSettings: DockzSettings) {
        settings = newSettings
        settings.save(to: paths)
        if let vmController {
            vmController.stop { [weak self] in self?.startVM() }
        } else {
            startVM()
        }
    }

    /// No disk image yet (first run). Offer to build it right here — the netboot
    /// builder needs no docker, so this works on an otherwise empty Mac.
    private func presentMissingDiskImageAlert() {
        // Already created (possibly hidden by the user mid-build): re-front it
        // instead of doing nothing, so "Start" from the menu always shows it.
        if let existing = imageSetupController {
            existing.bringToFront()
            return
        }
        let controller = GuestImageSetupWindowController()
        imageSetupController = controller
        controller.present(
            onImageReady: { [weak self] in
                guard let self else { return }
                self.display.diskImageMissing = false
                self.refreshMenu()
                self.startVM()
            },
            // Only now is it safe to let the controller go — it has closed itself.
            onDismiss: { [weak self] in self?.imageSetupController = nil }
        )
    }
}
