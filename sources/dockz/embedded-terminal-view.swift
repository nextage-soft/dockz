import AppKit

/// A shell command to run in a terminal.
struct TerminalCommand: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var executable: String
    var arguments: [String]
    var environment: [String: String] = [:]
}

/// Launches a TerminalCommand in the system Terminal.app by writing a small
/// executable `.command` script and opening it. DockZ has no bundled terminal
/// emulator dependency — it hands interactive sessions (SSH into machines,
/// `docker exec`) to the OS terminal.
enum TerminalLauncher {
    static func launch(_ command: TerminalCommand) {
        let directory = DockzPaths().baseDirectory.appendingPathComponent("terminals", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let slug = command.title.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let url = directory.appendingPathComponent("\(slug.isEmpty ? "session" : slug).command")

        var lines = ["#!/bin/bash"]
        for (key, value) in command.environment.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=\(shellQuote(value))")
        }
        let parts = ([command.executable] + command.arguments).map(shellQuote)
        lines.append("exec \(parts.joined(separator: " "))")

        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSLog("dockz: could not launch terminal: \(error.localizedDescription)")
        }
    }

    /// Single-quotes a string for safe use in the shell (handles embedded ').
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
