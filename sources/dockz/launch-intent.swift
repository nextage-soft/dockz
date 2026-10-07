import AppKit

/// How DockZ was started, so a user who opens it always gets a window.
///
/// DockZ lives in the menu bar. When the menu bar is crowded (or the notch
/// covers it) macOS hides its icon, and opening DockZ again from Finder,
/// Spotlight or Launchpad used to show nothing at all — it looked frozen.
/// Every user-initiated open now shows the dashboard; only a login-item launch
/// (Launch at Login) stays quietly in the menu bar.
enum LaunchIntent {
    /// True when macOS started DockZ as a login item. The launch Apple event
    /// (kAEOpenApplication) then carries keyAEPropData = keyAELaunchedAsLogInItem;
    /// read it in applicationDidFinishLaunching, while that event is current.
    static func launchedAsLoginItem(
        _ event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// Whether to open the dashboard right after launch. A missing VM image has
    /// its own setup window, so the dashboard waits for that.
    static func showsDashboardAtLaunch(launchedAsLoginItem: Bool, diskImageMissing: Bool) -> Bool {
        !launchedAsLoginItem && !diskImageMissing
    }
}
