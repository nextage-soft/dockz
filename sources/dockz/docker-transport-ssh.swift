import CryptoKit
import Foundation

/// Reaches a remote engine the way `docker -H ssh://…` does: run
/// `docker system dial-stdio` over the system's own /usr/bin/ssh and speak
/// HTTP through its stdin/stdout. Uses the user's keys, ssh-agent and
/// ~/.ssh/config (aliases, bastions); DockZ stores no secret.
enum SSHDockerConnector {
    /// The system ssh, or `DOCKZ_SSH` when set (like git's GIT_SSH) — lets a
    /// wrapper add options for one run without touching ~/.ssh.
    static var sshBinary: String {
        ProcessInfo.processInfo.environment["DOCKZ_SSH"] ?? "/usr/bin/ssh"
    }

    struct Target: Equatable {
        /// `user@host`, `host`, or a ~/.ssh/config alias.
        var destination: String
        var port: Int?
    }

    /// nil when usable. A destination starting with "-" would be parsed by ssh
    /// as an option (e.g. -oProxyCommand=…), so it is rejected outright, as is
    /// anything with whitespace or control characters.
    static func validationError(_ target: Target) -> String? {
        let destination = target.destination
        if destination.isEmpty { return "Enter a host, user@host, or ~/.ssh/config alias" }
        if destination.hasPrefix("-") { return "Host can't start with \"-\"" }
        if destination.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) { return "Host can't contain spaces" }
        if let port = target.port, !(1...65535).contains(port) { return "Port must be 1–65535" }
        return nil
    }

    /// Short, per-target path for the multiplexing master (unix socket paths
    /// are capped at 104 bytes, so the user-relocatable data folder is avoided).
    static func controlPath(for target: Target) -> String {
        let key = "\(target.destination):\(target.port ?? 22)"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "/tmp/dockz-ssh-\(digest)"
    }

    /// Options shared by the master and every request. BatchMode: a GUI app
    /// can't answer password prompts — key or agent auth only. accept-new:
    /// trust a host on first contact, refuse if its key later changes.
    static func baseArguments(_ target: Target) -> [String] {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ControlPath=\(controlPath(for: target))",
        ]
        if let port = target.port { arguments += ["-p", String(port)] }
        return arguments
    }

    static func requestArguments(_ target: Target) -> [String] {
        baseArguments(target) + ["-o", "ControlMaster=no", "--", target.destination,
                                 "docker", "system", "dial-stdio"]
    }

    static func open(_ target: Target) throws -> DockerByteStream {
        if let error = validationError(target) { throw DockzError.socketSetupFailed(error) }
        ensureMaster(target)

        let pair = try SocketPair.make()
        let child = FileHandle(fileDescriptor: pair.remote, closeOnDealloc: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshBinary)
        process.arguments = requestArguments(target)
        process.standardInput = child
        process.standardOutput = child
        let stderr = StderrCollector()
        process.standardError = stderr.pipe
        do {
            try process.run()
        } catch {
            Darwin.close(pair.local)
            Darwin.close(pair.remote)
            throw error
        }
        // The child holds its own copy; ours would keep the stream open forever.
        Darwin.close(pair.remote)

        return FileDescriptorStream(
            fileDescriptor: pair.local,
            onClose: { if process.isRunning { process.terminate() } },
            diagnostics: {
                // ssh writes its reason (auth, host key, docker missing) then exits.
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < deadline { usleep(50_000) }
                return stderr.text
            }
        )
    }

    // MARK: - Connection multiplexing

    private static let masterLock = NSLock()
    private static var masterLaunchedAt: [String: Date] = [:]

    /// Starts a backgrounded master (`-M -N -f`) once, so later requests reuse
    /// one authenticated connection instead of a full SSH handshake each.
    /// Its stdio goes to /dev/null: a daemonised master holding our pipes
    /// would keep streams from ever reaching EOF. Requests fall back to direct
    /// connections whenever no master is up.
    private static func ensureMaster(_ target: Target) {
        let path = controlPath(for: target)
        masterLock.lock()
        defer { masterLock.unlock() }
        if FileManager.default.fileExists(atPath: path) { return }
        if let last = masterLaunchedAt[path], Date().timeIntervalSince(last) < 15 { return }
        masterLaunchedAt[path] = Date()

        let master = Process()
        master.executableURL = URL(fileURLWithPath: sshBinary)
        master.arguments = baseArguments(target) + ["-M", "-N", "-f", "-o", "ControlPersist=120",
                                                    "--", target.destination]
        master.standardInput = FileHandle.nullDevice
        master.standardOutput = FileHandle.nullDevice
        master.standardError = FileHandle.nullDevice
        try? master.run()
    }
}

/// Drains a child's stderr as it arrives (a full pipe would block the child)
/// and keeps the tail for error messages.
final class StderrCollector {
    let pipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    init() {
        pipe.fileHandleForReading.readChunks { [weak self] chunk in
            guard let self else { return }
            self.lock.lock()
            self.buffer.append(chunk)
            if self.buffer.count > 8192 { self.buffer = self.buffer.suffix(4096) }
            self.lock.unlock()
        }
    }

    var text: String? {
        lock.lock()
        defer { lock.unlock() }
        let value = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
