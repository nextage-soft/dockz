import Foundation

/// One DockZ process owns a data folder at a time. Two copies on the same
/// folder would boot the same disk.img and machine disks; Virtualization then
/// refuses the second VM ("boot loader is invalid") and, before this lock,
/// that copy kept retrying while showing nothing useful.
///
/// An advisory `flock` on `<root>/.dockz.lock`: the kernel drops it when the
/// owning process exits (even on a crash), so a stale lock file never blocks
/// the next launch. The holder's PID is written into the file for the message.
final class DataRootLock {
    private let fileDescriptor: Int32

    enum Failure: Error, Equatable {
        /// Another live process holds the lock (its PID, when readable).
        case heldByAnotherProcess(pid: Int32?)
        case cannotOpen(String)
    }

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    static func lockFile(in root: URL) -> URL {
        root.appendingPathComponent(".dockz.lock")
    }

    /// Takes the lock or reports who holds it. Never blocks.
    static func acquire(root: URL) -> Result<DataRootLock, Failure> {
        let path = lockFile(in: root).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            return .failure(.cannotOpen("\(path): \(String(cString: strerror(errno)))"))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let holder = (try? String(contentsOfFile: path, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            close(fd)
            return .failure(.heldByAnotherProcess(pid: holder))
        }
        let pid = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return .success(DataRootLock(fileDescriptor: fd))
    }
}
