import Foundation

/// The one place that knows the unix-domain socket path limit. `sun_path` in
/// `sockaddr_un` is 104 bytes on macOS including the terminating NUL, so a
/// path may be at most 103 bytes. Every socket DockZ binds or connects to is
/// checked here, so an over-long path fails with a readable reason instead of
/// a silently missing socket (seen: a data folder nested deep enough that
/// `<root>/docker.sock` passed the limit — the VM ran, docker.sock never
/// appeared, and nothing told the user).
enum UnixSocketPath {
    static let maxBytes: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// nil when `path` fits; otherwise a sentence saying why it does not.
    static func problem(_ path: String) -> String? {
        let length = path.utf8.count
        guard length > maxBytes else { return nil }
        return "The socket path \(path) is \(length) bytes long; macOS allows at most \(maxBytes). Move the DockZ data folder somewhere with a shorter path."
    }

    /// Problems with every socket DockZ creates inside a data root — checked
    /// before choosing a data folder, so it is refused up front.
    static func problems(inDataRoot root: URL) -> [String] {
        let paths = DockzPaths(baseDirectory: root)
        return [paths.dockerSocket.path, paths.debugShellSocket.path].compactMap(problem)
    }
}
