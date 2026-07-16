import Foundation

/// Builds a cloud-init NoCloud seed ISO (volume label "cidata") that injects
/// the DockZ machines SSH key and hostname into a Debian/Ubuntu cloud image on
/// first boot. Uses macOS's built-in `hdiutil makehybrid` — no dependencies.
enum CloudInitSeed {
    static func makeSeedISO(at destination: URL, hostname: String, publicKey: String) throws {
        let workDir = destination.deletingLastPathComponent()
            .appendingPathComponent("cidata-\(hostname)", isDirectory: true)
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let userData = """
        #cloud-config
        hostname: \(hostname)
        preserve_hostname: false
        ssh_pwauth: false
        disable_root: false
        users:
          - name: root
            lock_passwd: false
            ssh_authorized_keys:
              - \(publicKey)
        write_files:
          - path: /etc/ssh/sshd_config.d/10-dockz.conf
            content: |
              PermitRootLogin prohibit-password
        runcmd:
          - [ systemctl, restart, ssh ]
          - [ systemctl, restart, sshd ]
        """
        let metaData = """
        instance-id: \(hostname)
        local-hostname: \(hostname)
        """
        try userData.write(to: workDir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try metaData.write(to: workDir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)

        try? FileManager.default.removeItem(at: destination)
        let hdiutil = Process()
        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = [
            "makehybrid", "-iso", "-joliet",
            "-default-volume-name", "cidata",
            "-o", destination.path,
            workDir.path,
        ]
        hdiutil.standardOutput = FileHandle.nullDevice
        hdiutil.standardError = FileHandle.nullDevice
        try hdiutil.run()
        hdiutil.waitUntilExit()
        guard hdiutil.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw DockzError.socketSetupFailed("cloud-init seed ISO build failed")
        }
    }
}
