import AppKit
import Virtualization

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = DockzPaths()
    private var settings = DockzSettings()
    private var menuController: StatusMenuController?
    private var vmController: VMController?
    private var restartPolicy = VMRestartPolicy()
    private let engineWatchdog = EngineWatchdog()
    private var bringup: DockerBringupCoordinator?
    private var display = StatusMenuController.DisplayState()
    private let dashboardStore = DashboardStore()
    private var dashboardController: DashboardWindowController?
    private var imageSetupController: GuestImageSetupWindowController?
    /// Held for the life of the process (see data-root-lock.swift).
    private var dataRootLock: DataRootLock?
    /// Shown while quitting stops the VMs (see shutdown-progress-window.swift).
    private var shutdownWindow: ShutdownWindowController?

    /// Becomes the only owner of the data folder, or explains who is and quits.
    private func claimDataFolder() -> Bool {
        switch DataRootLock.acquire(root: paths.baseDirectory) {
        case .success(let lock):
            dataRootLock = lock
            return true
        case .failure(.heldByAnotherProcess(let pid)):
            HostLog.write("data folder already owned by PID \(pid.map(String.init) ?? "?") — not starting a second copy")
            let other = pid.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
            let alert = NSAlert()
            alert.messageText = "DockZ is already running"
            alert.informativeText = "Another copy of DockZ\(pid.map { " (PID \($0))" } ?? "") is using the data folder \(paths.baseDirectory.path). Only one copy can run its virtual machines at a time, so this one will quit."
            alert.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            other?.activate()
            NSApp.terminate(nil)
            return false
        case .failure(.cannotOpen(let reason)):
            // Not fatal: an unwritable lock file must not stop DockZ from
            // starting; it only loses the duplicate-launch protection.
            HostLog.write("data folder lock unavailable: \(reason)")
            return true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything else: the launch Apple event is only current now.
        let launchedAsLoginItem = LaunchIntent.launchedAsLoginItem()
        try? paths.ensureBaseDirectory()
        guard claimDataFolder() else { return }
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
        if LaunchIntent.showsDashboardAtLaunch(launchedAsLoginItem: launchedAsLoginItem,
                                               diskImageMissing: !paths.diskImageExists) {
            openDashboard()
        }
    }

    /// Opening DockZ again while it runs (Finder, Spotlight, Launchpad, Dock)
    /// must always show something: its menu bar icon may be hidden by a
    /// crowded menu bar, and doing nothing here made the app look frozen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "dockz" }) {
            openDashboard()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if refuseWhileDiskMaintenance() { return .terminateCancel }
        let dockerRunning = vmController != nil && (display.vmState == .running || display.vmState == .starting)
        let runningMachines = dashboardStore.machineManager.machines
            .filter { $0.state == .running || $0.state == .starting }
            .map(\.name)
        let plan = ShutdownPlan(dockerRunning: dockerRunning, runningMachines: runningMachines)
        guard !plan.isEmpty else { return .terminateNow }
        // A second quit request while shutting down is already handled.
        guard shutdownWindow == nil else { return .terminateLater }

        // Stopping the VMs takes seconds: show what is happening (see
        // shutdown-progress-window.swift) rather than an app that looks frozen.
        let progress = ShutdownProgress(plan: plan)
        let window = ShutdownWindowController(progress: progress)
        shutdownWindow = window
        window.present()

        bringup?.stop()
        bringup = nil
        let group = DispatchGroup()
        if dockerRunning, let vmController {
            group.enter()
            vmController.stop {
                DispatchQueue.main.async { progress.finish(ShutdownPlan.dockerStep) }
                group.leave()
            }
        }
        group.enter()
        dashboardStore.machineManager.stopAll {
            DispatchQueue.main.async { progress.finish(ShutdownPlan.machinesStep) }
            group.leave()
        }
        group.notify(queue: .main) {
            // Let the last checkmark show for a moment before the window goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
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
        guard vmController == nil, display.diskMaintenance == nil else { return }
        if DiskShrinker.recoverInterruptedShrink(disk: paths.diskImage) {
            dashboardStore.lastError = "DockZ quit while shrinking the disk, so the shrink was undone. The disk is back to its earlier size."
        }
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
            let kind = VMRestartPolicy.classify(
                stopWasRequested: vmController?.stopWasRequested ?? true,
                reachedRunning: vmController?.reachedRunning ?? false)
            engineWatchdog.stop()
            bringup?.stop()
            bringup = nil
            vmController = nil
            display.dockerReady = false
            display.guestIP = nil
            display.forwardedPorts = []
            switch kind {
            case .requested:
                break
            case .crashed:
                recoverFromUnexpectedStop(state)
            case .failedToStart:
                let reason: String
                if case .failed(let message) = state { reason = message } else { reason = "it stopped while booting" }
                HostLog.write("VM failed to start (\(reason)) — not retrying")
                dashboardStore.lastError = "The Docker VM could not start: \(reason)"
            }
        case .starting, .stopping:
            break
        }
        refreshMenu()
    }

    // MARK: - Recovery (see vm-supervisor.swift)

    /// The guest rebooted itself (kernel guard) or Virtualization failed:
    /// bring the engine back, unless it keeps dying.
    private func recoverFromUnexpectedStop(_ state: VMState) {
        guard restartPolicy.allowRestart(at: ProcessInfo.processInfo.systemUptime) else {
            HostLog.write("VM keeps stopping — not restarting again (\(restartPolicy.maxRestarts) restarts within \(Int(restartPolicy.window / 60)) min)")
            dashboardStore.lastError = "The Docker VM stopped unexpectedly several times in a row, so DockZ stopped restarting it. Details are in host.log and console.*.log in the data folder."
            return
        }
        HostLog.write("unexpected stop (\(state)) — restarting the VM")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startVM() }
    }

    /// The VM is up but dockerd has not answered for a minute: the guest is
    /// wedged (seen: kernel oops → ext4 deadlock). Restart it.
    private func restartUnresponsiveEngine() {
        guard let vmController, restartPolicy.allowRestart(at: ProcessInfo.processInfo.systemUptime) else {
            HostLog.write("engine unresponsive — restart limit reached, leaving the VM as is")
            return
        }
        HostLog.write("engine unresponsive (no /_ping answer for a minute) — restarting the VM")
        dashboardStore.lastError = "The Docker engine stopped responding, so DockZ restarted its VM. Containers with a restart policy come back by themselves."
        vmController.stop { [weak self] in self?.startVM() }
    }

    private func startBringup() {
        guard let vmController else { return }
        let coordinator = DockerBringupCoordinator(vm: vmController, paths: paths)
        coordinator.onUpdate = { [weak self] in self?.bringupUpdated() }
        bringup = coordinator
        coordinator.start()
        if let problem = coordinator.setupError {
            dashboardStore.lastError = problem
        }
    }

    private func bringupUpdated() {
        guard let bringup else { return }
        // Guest clock zone is not persisted in a way we control across image
        // rebuilds, so push it every time the engine comes up.
        if bringup.dockerReady && !display.dockerReady {
            pushGuestTimeZone(completion: nil)
            if let connect = vmController?.vsockConnector() {
                GuestKernelGuard.apply(connect: connect) { _ in }
                // Images built by an older DockZ keep their guest files;
                // bring them up to the app's copy (see guest-rootfs-sync.swift).
                GuestRootfsSync.apply(connect: connect)
            }
            engineWatchdog.start(api: { [weak self] in self?.bringup?.apiClient }) { [weak self] in
                self?.restartUnresponsiveEngine()
            }
        }
        display.dockerReady = bringup.dockerReady
        display.guestIP = bringup.guestIP
        display.forwardedPorts = bringup.forwardedPorts
        refreshMenu()
    }

    private func pushGuestTimeZone(completion: ((String?) -> Void)?) {
        guard let connect = vmController?.vsockConnector() else {
            completion?("VM is not running")
            return
        }
        GuestTimeZone.apply(setting: settings.timeZone, connect: connect) { error in
            DispatchQueue.main.async { completion?(error) }
        }
    }

    private func refreshMenu() {
        menuController?.update(display)
        // Push the state into the dashboard too — its views must react the
        // instant a Stop/Restart lands, not on the next poll.
        dashboardStore.vmDisplayState = vmStateLabelText
    }

    private var vmStateLabelText: String {
        switch display.vmState {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .failed: return "Failed"
        }
    }

    // MARK: - Dashboard

    private func configureDashboardStore() {
        dashboardStore.localAPIProvider = { [weak self] in self?.bringup?.apiClient }
        // Screen lock / sleep relocks TLS keys; don't leave the dashboard
        // pointed at an engine it can no longer reach.
        dashboardStore.environments.onSelectedEnvironmentLocked = { [weak dashboardStore] environment in
            dashboardStore?.switchEnvironment(to: nil)
            dashboardStore?.lastError = "\(environment.name) locked — select it again to unlock with Touch ID"
        }
        dashboardStore.localShellProvider = { [weak self] in
            guard let self, self.display.vmState == .running else { return nil }
            return self.vmController?.vsockConnector()
        }
        dashboardStore.hostActions = .init(
            restartVM: { [weak self] newSettings in self?.applySettingsAndRestart(newSettings) },
            currentSettings: { [weak self] in self?.settings ?? DockzSettings() },
            startVM: { [weak self] in self?.startVM() },
            stopVM: { [weak self] in self?.vmController?.stop() },
            storagePath: { StorageLocation.currentRoot.path },
            changeStorage: { [weak self] parent in self?.changeStorageLocation(toParent: parent) },
            resetStorage: { [weak self] in self?.changeStorageLocation(toParent: nil) },
            snapshots: { [weak self] in self.map { SnapshotStore.list($0.paths) } ?? [] },
            createSnapshot: { [weak self] name in self?.createSnapshot(named: name) },
            restoreSnapshot: { [weak self] id in self?.restoreSnapshot(id: id) },
            deleteSnapshot: { [weak self] id in
                guard let self else { return }
                SnapshotStore.delete(self.paths, id: id)
            },
            applyTimeZone: { [weak self] zone, done in
                guard let self else { return }
                self.settings.timeZone = zone
                self.settings.save(to: self.paths)
                // Stopped VM: saved now, applied at the next boot.
                guard self.display.dockerReady else { return done(nil) }
                self.pushGuestTimeZone(completion: done)
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
    /// Shrinking needs the filesystem shrunk first, offline — that is done by
    /// shrinkDiskToLimit on Apply, never here.
    private func ensureDiskLimit() {
        guard let current = DiskUsage.apparentBytes(at: paths.diskImage),
              case .grow(let limitBytes) = DiskLimit.change(currentBytes: current, limitGB: settings.diskLimitGB),
              let handle = try? FileHandle(forWritingTo: paths.diskImage) else { return }
        try? handle.truncate(atOffset: limitBytes)
        try? handle.close()
        NSLog("dockz: disk grown to \(settings.diskLimitGB)G (sparse)")
    }

    /// Moves the whole data directory to a new location (or back to default),
    /// then quits so everything re-resolves cleanly on next launch. Safest
    /// approach: no live re-pointing of open disk images.
    private func changeStorageLocation(toParent parent: URL?) {
        guard !refuseWhileDiskMaintenance() else { return }
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
        guard !refuseWhileDiskMaintenance() else { return }
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

    /// True (after telling the user) while the disk is being shrunk — nothing
    /// else may touch disk.img until it finishes.
    private func refuseWhileDiskMaintenance() -> Bool {
        guard let maintenance = display.diskMaintenance else { return false }
        presentError("DockZ is busy with the VM disk",
                     "\(maintenance)\n\nTry again when it has finished — Docker starts again by itself.")
        return true
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
        if !settings.save(to: paths) {
            // Apply in memory anyway, but a silent save failure would surface
            // as "settings randomly reverted after quit" — say it now.
            presentError("Could not save settings",
                         "The new values apply to this run but could not be written to \(paths.configFile.path); they will revert when DockZ quits.")
        }
        let restart = { [weak self] in
            self?.shrinkDiskToLimit { self?.startVM() }
        }
        if let vmController {
            vmController.stop { restart() }
        } else {
            restart()
        }
    }

    /// A limit below the disk's size takes effect here, with the VM stopped:
    /// the disk is shrunk offline (DiskShrinker), then `done` starts it again.
    /// If the shrink cannot be done the disk is left as it was and the limit
    /// is set back to the disk's real size, so Settings never shows a limit
    /// that is not enforced.
    private func shrinkDiskToLimit(then done: @escaping () -> Void) {
        let disk = paths.diskImage
        guard let current = DiskUsage.apparentBytes(at: disk),
              case .shrink(let target) = DiskLimit.change(currentBytes: current, limitGB: settings.diskLimitGB)
        else { return done() }
        let limitGB = settings.diskLimitGB
        let headline = "Shrinking the disk to \(limitGB) GB"
        setDiskMaintenance("\(headline)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try DiskShrinker.shrink(disk: disk, toBytes: target, limitGB: limitGB) { step in
                    DispatchQueue.main.async { self?.setDiskMaintenance("\(headline) — \(step)…") }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.setDiskMaintenance(nil)
                if case .failure(let error) = result {
                    HostLog.write("disk shrink to \(limitGB) GB failed: \(error.localizedDescription)")
                    self.settings.diskLimitGB = Int(current / DiskLimit.bytesPerGB)
                    self.settings.save(to: self.paths)
                    self.dashboardStore.lastError = "The disk was not shrunk to \(limitGB) GB and is unchanged. \(error.localizedDescription)"
                }
                done()
            }
        }
    }

    private func setDiskMaintenance(_ text: String?) {
        display.diskMaintenance = text
        dashboardStore.diskMaintenance = text
        refreshMenu()
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
