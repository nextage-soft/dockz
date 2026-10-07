import Foundation

/// `DockZ shrink-disk` — shrinks disk.img to the disk limit in config.json,
/// without the app (the dashboard does the same on Apply & Restart). Holds
/// the data-folder lock throughout, so it refuses while DockZ is open.
enum DiskShrinkCLI {
    static func run() -> Never {
        DispatchQueue.global().async {
            let paths = DockzPaths()
            let lock: DataRootLock
            switch DataRootLock.acquire(root: paths.baseDirectory) {
            case .success(let held):
                lock = held
            case .failure(.heldByAnotherProcess(let pid)):
                print("dockz: DockZ is using \(paths.baseDirectory.path)\(pid.map { " (PID \($0))" } ?? "") — quit it first")
                exit(1)
            case .failure(.cannotOpen(let reason)):
                print("dockz: cannot lock \(paths.baseDirectory.path): \(reason)")
                exit(1)
            }
            let limitGB = DockzSettings.load(from: paths).diskLimitGB
            guard let current = DiskUsage.apparentBytes(at: paths.diskImage),
                  case .shrink(let target) = DiskLimit.change(currentBytes: current, limitGB: limitGB) else {
                print("dockz: \(paths.diskImage.path) is not larger than the \(limitGB) GB limit — nothing to do")
                exit(0)
            }
            print("dockz: shrinking \(paths.diskImage.path) from \(DiskLimit.format(current)) to \(limitGB) GB")
            do {
                try DiskShrinker.shrink(disk: paths.diskImage, toBytes: target, limitGB: limitGB) {
                    print("dockz: \($0)")
                }
                print("dockz: done — the disk is now \(DiskLimit.format(DiskUsage.apparentBytes(at: paths.diskImage) ?? 0))")
                withExtendedLifetime(lock) { exit(0) }
            } catch {
                print("dockz: shrink FAILED, disk unchanged — \(error.localizedDescription)")
                withExtendedLifetime(lock) { exit(1) }
            }
        }
        dispatchMain()
    }
}
