import Foundation

/// Wires the managed docker CLI into the user's interactive shell without any
/// copy-paste: appends a marked, removable block to the shell's rc file.
///
/// The block is conditional — it only takes effect while the Mac has no system
/// `docker` — so a later Homebrew or Docker Desktop install wins automatically
/// and DockZ's exports (including DOCKER_CONFIG) step aside.
enum ShellIntegrationInstaller {
    static let beginMarker = "# >>> DockZ docker CLI >>>"
    static let endMarker = "# <<< DockZ docker CLI <<<"

    static func block(_ paths: DockzPaths = DockzPaths()) -> String {
        """
        \(beginMarker)
        # Added by DockZ (Settings → Docker CLI). Safe to delete.
        if ! command -v docker >/dev/null 2>&1; then
            export PATH="\(paths.managedCLIDirectory.path):$PATH"
            export DOCKER_CONFIG="\(paths.managedDockerConfig.path)"
        fi
        \(endMarker)
        """
    }

    /// rc file for the user's login shell. zsh reads .zshrc for every
    /// interactive shell; bash on macOS reads .bash_profile (Terminal opens
    /// login shells); anything else gets the POSIX fallback.
    static func rcFileURL(shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch (shellPath as NSString).lastPathComponent {
        case "zsh": return home.appendingPathComponent(".zshrc")
        case "bash": return home.appendingPathComponent(".bash_profile")
        default: return home.appendingPathComponent(".profile")
        }
    }

    /// Appends the block (no-op when already present, wherever it is).
    static func adding(to contents: String, block: String) -> String {
        guard !contents.contains(beginMarker) else { return contents }
        var result = contents
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty { result += "\n" }
        return result + block + "\n"
    }

    /// Removes every marked block, whatever DockZ wrote into it over the years
    /// — the markers are the contract, not the block body.
    static func removing(from contents: String) -> String {
        var kept: [Substring] = []
        var inBlock = false
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(beginMarker) { inBlock = true; continue }
            if line.hasPrefix(endMarker) { inBlock = false; continue }
            if !inBlock { kept.append(line) }
        }
        var result = kept.joined(separator: "\n")
        // Collapse the blank separator the block was appended with.
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }

    static func isInstalled() -> Bool {
        guard let contents = try? String(contentsOf: rcFileURL(), encoding: .utf8) else { return false }
        return contents.contains(beginMarker)
    }

    static func install(_ paths: DockzPaths = DockzPaths()) throws {
        let rc = rcFileURL()
        let contents = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
        let updated = adding(to: contents, block: block(paths))
        guard updated != contents else { return }
        try updated.write(to: rc, atomically: true, encoding: .utf8)
    }

    static func uninstall() throws {
        let rc = rcFileURL()
        guard let contents = try? String(contentsOf: rc, encoding: .utf8),
              contents.contains(beginMarker) else { return }
        try removing(from: contents).write(to: rc, atomically: true, encoding: .utf8)
    }

    /// `DockZ setup-shell [--remove]` — same integration from a terminal,
    /// which is also how automated tests exercise the file plumbing.
    static func runCLI(remove: Bool) -> Never {
        do {
            if remove {
                try uninstall()
                print("dockz: shell block removed from \(rcFileURL().path)")
            } else {
                try install()
                print("dockz: shell block written to \(rcFileURL().path) — open a new terminal")
            }
            exit(0)
        } catch {
            print("dockz: shell setup FAILED — \(error.localizedDescription)")
            exit(1)
        }
    }
}
