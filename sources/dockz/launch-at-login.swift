import Foundation
import ServiceManagement

/// Start DockZ when the user logs in, via SMAppService (macOS 13+). The system
/// owns the state — no preference file to keep in sync; `isEnabled` reads the
/// live registration status. The user can also manage it in
/// System Settings → General → Login Items.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration can require user approval (macOS shows a notification and
    /// the item appears in Login Items); .requiresApproval is not an error here.
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
