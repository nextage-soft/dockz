import AppKit
import SwiftUI

/// Hosts the SwiftUI dashboard in a regular window (the app is LSUIElement,
/// so the window is activated explicitly when opened from the menu bar).
@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let store: DashboardStore

    init(store: DashboardStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DockZ"
        // Custom chrome: content fills the titlebar area, traffic lights
        // float over our own header/sidebar (Docker Desktop style).
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardRootView(store: store))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        store.startAutoRefresh()
        // The app normally lives as a menu-bar accessory; while the dashboard
        // is open it becomes a regular app (Dock icon, ⌘Tab switcher).
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        store.stopAutoRefresh()
        NSApp.setActivationPolicy(.accessory)
    }
}
