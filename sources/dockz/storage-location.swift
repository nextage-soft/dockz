import Foundation

/// Resolves where DockZ keeps its VM data. Defaults to ~/.dockz but can be
/// pointed at an external SSD. The chosen path is stored in UserDefaults and
/// read very early (before any VM starts), so DockzPaths() honours it.
enum StorageLocation {
    private static let defaultsKey = "dockz.storageRoot"

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dockz", isDirectory: true)
    }

    /// The active data root. Falls back to the default if the stored path is
    /// gone (e.g. an external drive was unplugged) so the app still launches.
    static var currentRoot: URL {
        guard let path = UserDefaults.standard.string(forKey: defaultsKey), !path.isEmpty else {
            return defaultRoot
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return defaultRoot
    }

    static var isCustom: Bool {
        (UserDefaults.standard.string(forKey: defaultsKey) ?? "").isEmpty == false
    }

    /// Moves the whole data directory to `newParent/dockz-data` and repoints
    /// the app there. Caller must have stopped all VMs first. Throws on failure
    /// leaving the original data untouched.
    static func migrate(toParent newParent: URL) throws {
        let source = currentRoot
        let destination = newParent.appendingPathComponent("dockz-data", isDirectory: true)

        guard destination.path != source.path else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw DockzError.socketSetupFailed("\(destination.path) already exists — choose an empty location")
        }
        // Verify the target volume is writable before touching anything.
        guard FileManager.default.isWritableFile(atPath: newParent.path) else {
            throw DockzError.socketSetupFailed("no write permission at \(newParent.path)")
        }

        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        UserDefaults.standard.set(destination.path, forKey: defaultsKey)
    }

    /// Reverts to the default ~/.dockz location (moves data back).
    static func resetToDefault() throws {
        let source = currentRoot
        guard source.path != defaultRoot.path else { return }
        if FileManager.default.fileExists(atPath: defaultRoot.path) {
            throw DockzError.socketSetupFailed("\(defaultRoot.path) already exists")
        }
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: defaultRoot)
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
