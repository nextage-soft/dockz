import AppKit

/// Menu bar UI: a status item whose menu is rebuilt from the current state.
@MainActor
final class StatusMenuController: NSObject {
    struct Actions {
        var openDashboard: () -> Void
        var startVM: () -> Void
        var stopVM: () -> Void
        var useDockerContext: () -> Void
        var openConsoleLog: () -> Void
        var openDataFolder: () -> Void
        var quit: () -> Void
    }

    struct DisplayState {
        var vmState: VMState = .stopped
        var dockerReady = false
        var guestIP: String?
        var forwardedPorts: [UInt16] = []
        var rosettaAvailable = false
        var diskImageMissing = false
    }

    private let statusItem: NSStatusItem
    private let actions: Actions
    private var display = DisplayState()

    init(actions: Actions) {
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = BrandContainerIcon.statusItemImage()
        }
        rebuildMenu()
    }

    func update(_ newState: DisplayState) {
        display = newState
        rebuildMenu()
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(infoItem(title: "\(AppInfo.name) \(AppInfo.versionLong)"))
        menu.addItem(.separator())
        let dashboardItem = actionItem(title: "Open Dashboard…", action: #selector(openDashboard))
        dashboardItem.keyEquivalent = "d"
        menu.addItem(dashboardItem)
        menu.addItem(.separator())
        menu.addItem(infoItem(title: "VM: \(vmStateLabel)"))
        if display.diskImageMissing {
            menu.addItem(infoItem(title: "Disk image missing — run guest/build-guest-image.sh"))
        }
        menu.addItem(infoItem(title: "Docker: \(dockerLabel)"))
        if let guestIP = display.guestIP {
            menu.addItem(infoItem(title: "Guest IP: \(guestIP)"))
        }
        if !display.forwardedPorts.isEmpty {
            let ports = display.forwardedPorts.map(String.init).joined(separator: ", ")
            menu.addItem(infoItem(title: "Forwarded ports: \(ports)"))
        }
        menu.addItem(infoItem(title: "Rosetta (amd64): \(display.rosettaAvailable ? "available" : "not installed")"))
        menu.addItem(.separator())

        switch display.vmState {
        case .stopped, .failed:
            menu.addItem(actionItem(title: "Start VM", action: #selector(startVM), enabled: !display.diskImageMissing))
        case .starting, .stopping:
            menu.addItem(infoItem(title: display.vmState == .starting ? "Starting…" : "Stopping…"))
        case .running:
            menu.addItem(actionItem(title: "Stop VM", action: #selector(stopVM)))
        }
        menu.addItem(actionItem(title: "Use \"dockz\" Docker Context", action: #selector(useContext), enabled: display.dockerReady))
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Open Console Log", action: #selector(openConsoleLog)))
        menu.addItem(actionItem(title: "Open ~/.dockz Folder", action: #selector(openDataFolder)))
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit DockZ", action: #selector(quit)))
        statusItem.menu = menu
    }

    private var vmStateLabel: String {
        switch display.vmState {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .failed(let message): return "Failed — \(message)"
        }
    }

    private var dockerLabel: String {
        guard display.vmState == .running else { return "Offline" }
        return display.dockerReady ? "Ready" : "Waiting for engine…"
    }

    private func infoItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    // MARK: - Actions

    @objc private func openDashboard() { actions.openDashboard() }
    @objc private func startVM() { actions.startVM() }
    @objc private func stopVM() { actions.stopVM() }
    @objc private func useContext() { actions.useDockerContext() }
    @objc private func openConsoleLog() { actions.openConsoleLog() }
    @objc private func openDataFolder() { actions.openDataFolder() }
    @objc private func quit() { actions.quit() }
}
