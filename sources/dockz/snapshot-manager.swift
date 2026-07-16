import Foundation

/// A point-in-time copy of the docker VM disk. Snapshots are APFS clones of
/// disk.img (instant, copy-on-write) kept under ~/.dockz/snapshots/. The VM
/// must be stopped while cloning/restoring; the AppDelegate coordinates that.
struct DiskSnapshot: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var createdAt: String   // ISO8601

    var fileName: String { "\(id).img" }
}

enum SnapshotStore {
    static func directory(_ paths: DockzPaths) -> URL {
        paths.baseDirectory.appendingPathComponent("snapshots", isDirectory: true)
    }

    private static func indexFile(_ paths: DockzPaths) -> URL {
        directory(paths).appendingPathComponent("index.json")
    }

    static func list(_ paths: DockzPaths) -> [DiskSnapshot] {
        guard let data = try? Data(contentsOf: indexFile(paths)),
              let items = try? JSONDecoder().decode([DiskSnapshot].self, from: data) else { return [] }
        // Only report snapshots whose disk file still exists.
        return items.filter {
            FileManager.default.fileExists(atPath: directory(paths).appendingPathComponent($0.fileName).path)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private static func save(_ items: [DiskSnapshot], _ paths: DockzPaths) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) {
            try? data.write(to: indexFile(paths))
        }
    }

    /// Clones the current disk.img into a new snapshot. Caller must have stopped
    /// the VM first. `id` and `timestamp` are injected for testability.
    static func create(_ paths: DockzPaths, name: String, id: String, timestamp: String) throws {
        let dir = directory(paths)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let snapshot = DiskSnapshot(id: id, name: name.isEmpty ? "Snapshot" : name, createdAt: timestamp)
        let destination = dir.appendingPathComponent(snapshot.fileName)

        let clone = Process()
        clone.executableURL = URL(fileURLWithPath: "/bin/cp")
        clone.arguments = ["-c", paths.diskImage.path, destination.path]  // APFS clone
        try clone.run()
        clone.waitUntilExit()
        guard clone.terminationStatus == 0 else {
            throw DockzError.socketSetupFailed("snapshot clone failed")
        }
        var items = list(paths)
        items.append(snapshot)
        save(items, paths)
    }

    /// Restores a snapshot over disk.img (VM must be stopped). The current disk
    /// is replaced; take a snapshot first if you want to keep it.
    static func restore(_ paths: DockzPaths, id: String) throws {
        let source = directory(paths).appendingPathComponent("\(id).img")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw DockzError.socketSetupFailed("snapshot not found")
        }
        let temp = paths.diskImage.appendingPathExtension("restoring")
        _ = try? FileManager.default.removeItem(at: temp)
        // Clone the snapshot to a temp, then atomically swap it in.
        let clone = Process()
        clone.executableURL = URL(fileURLWithPath: "/bin/cp")
        clone.arguments = ["-c", source.path, temp.path]
        try clone.run()
        clone.waitUntilExit()
        guard clone.terminationStatus == 0 else {
            throw DockzError.socketSetupFailed("snapshot restore clone failed")
        }
        _ = try? FileManager.default.removeItem(at: paths.diskImage)
        try FileManager.default.moveItem(at: temp, to: paths.diskImage)
    }

    static func delete(_ paths: DockzPaths, id: String) {
        try? FileManager.default.removeItem(at: directory(paths).appendingPathComponent("\(id).img"))
        save(list(paths).filter { $0.id != id }, paths)
    }
}
