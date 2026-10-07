import Foundation

/// Brings the guest's DockZ files up to date with the app after every boot.
///
/// guest/rootfs/ is copied into disk.img once, when the image is built, so a
/// fix to those files never reached an existing VM: the socat relay timeout
/// that dropped `docker run` output (dockz-agent) stayed broken on every disk
/// built before the fix. This writes each file whose content differs from the
/// copy bundled with the app, then restarts the services whose init script
/// changed — the guest ends up as a freshly built image would be.
///
/// Boot-path files are left alone: a mistake in them makes the VM unbootable,
/// and the only way back is rebuilding the image, which wipes Docker data.
/// Changes to them still reach new images.
enum GuestRootfsSync {
    /// Relative paths (inside rootfs/) that are never synced live.
    static let bootPathPrefixes = ["boot/", "etc/fstab", "etc/mkinitfs/", "etc/network/"]

    struct File: Equatable {
        let path: String        // relative to rootfs/, e.g. "etc/init.d/dockz-agent"
        let contents: Data
        let executable: Bool
    }

    /// Directories whose files the image build makes executable (chmod +x in
    /// provision-inside-vm.sh and the Dockerfile); the repo copies are 644.
    static let executableDirectories = ["etc/init.d/", "usr/local/bin/"]

    static func isSynced(_ relativePath: String) -> Bool {
        !bootPathPrefixes.contains { relativePath.hasPrefix($0) }
    }

    /// The bundled rootfs/ files that are synced live.
    static func bundledFiles(rootfs: URL) -> [File] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootfs, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let base = rootfs.standardizedFileURL.path + "/"
        var files: [File] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true, let data = try? Data(contentsOf: url) else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            guard isSynced(relative) else { continue }
            let executable = executableDirectories.contains { relative.hasPrefix($0) }
            files.append(File(path: relative, contents: data, executable: executable))
        }
        return files.sorted { $0.path < $1.path }
    }

    static let changedMarker = "DOCKZ-SYNC-CHANGED:"
    static let doneMarker = "DOCKZ-SYNC-DONE"

    /// Shell script for the guest. Each file is compared byte for byte and
    /// replaced atomically only when it differs. Changed services restart
    /// detached and a second later, so this shell session (which runs under
    /// dockz-agent itself) finishes first.
    static func script(for files: [File]) -> String {
        var lines = ["changed_services=''"]
        for file in files {
            let target = "/" + file.path
            let temporary = target + ".dockz-sync"
            lines.append("echo '\(file.contents.base64EncodedString())' | base64 -d > '\(temporary)'")
            lines.append("chmod \(file.executable ? "755" : "644") '\(temporary)'")
            lines.append("if cmp -s '\(temporary)' '\(target)'; then rm -f '\(temporary)'; else "
                + "mv -f '\(temporary)' '\(target)' && echo '\(changedMarker)\(file.path)'"
                + (file.path.hasPrefix("etc/init.d/")
                   ? " && changed_services=\"$changed_services \((file.path as NSString).lastPathComponent)\""
                   : "")
                + "; fi")
        }
        lines.append("""
        for svc in $changed_services; do
          rc-service "$svc" status >/dev/null 2>&1 && setsid sh -c "sleep 1; rc-service $svc restart" >/dev/null 2>&1 &
        done
        echo \(doneMarker)
        """)
        return lines.joined(separator: "\n")
    }

    /// Paths reported as changed, or nil when the script did not complete.
    static func changedPaths(fromOutput output: String) -> [String]? {
        guard output.contains(doneMarker) else { return nil }
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let range = line.range(of: changedMarker) else { return nil }
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
    }

    static func apply(connect: @escaping DockerAPIClient.VsockConnect) {
        guard let rootfs = ImageBuilderCLI.locateGuestDirectory()?.appendingPathComponent("rootfs", isDirectory: true)
        else {
            HostLog.write("guest sync: bundled guest/rootfs not found — skipped")
            return
        }
        let files = bundledFiles(rootfs: rootfs)
        guard !files.isEmpty else { return }
        GuestShellRunner.run(script: script(for: files), connect: connect) { output in
            guard let changed = output.flatMap(changedPaths(fromOutput:)) else {
                HostLog.write("guest sync: did not complete")
                return
            }
            if !changed.isEmpty {
                HostLog.write("guest sync: updated \(changed.joined(separator: ", "))")
            }
        }
    }
}
