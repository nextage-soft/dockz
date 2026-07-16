import Foundation

/// Shared SSH key for machines (usable from both GUI and CLI paths).
enum MachineSSHKey {
    static var directory: URL {
        DockzPaths().baseDirectory.appendingPathComponent("machines", isDirectory: true)
    }
    static var privateKeyURL: URL { directory.appendingPathComponent("id_ed25519") }
    static var baseImageURL: URL { directory.appendingPathComponent(".base-alpine.img") }

    static func ensure() -> String? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let publicKeyURL = privateKeyURL.appendingPathExtension("pub")
        if let key = try? String(contentsOf: publicKeyURL, encoding: .utf8) {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-t", "ed25519", "-N", "", "-C", "dockz-machines", "-f", privateKeyURL.path]
        keygen.standardOutput = FileHandle.nullDevice
        keygen.standardError = FileHandle.nullDevice
        try? keygen.run()
        keygen.waitUntilExit()
        return (try? String(contentsOf: publicKeyURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Headless helpers: `DockZ build-machine-base` and `DockZ machine-smoke` —
/// used for automation and end-to-end verification of the machines feature.
enum MachineCLI {
    static func runBuildBase() -> Never {
        DispatchQueue.global().async {
            do {
                guard let key = MachineSSHKey.ensure() else {
                    throw DockzError.socketSetupFailed("ssh-keygen failed")
                }
                try ImageBuilderCLI.buildDiskImage(ImageBuilderCLI.BuildRequest(
                    outputURL: MachineSSHKey.baseImageURL,
                    sizeGB: 4,
                    profile: "machine",
                    publicKey: key,
                    progress: { print("machines: \($0)") }
                ))
                exit(0)
            } catch {
                print("machines: base build FAILED — \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }

    /// Clone → boot → wait for IP → ssh uname → poweroff. Prints MACHINE SMOKE OK.
    static func runSmoke(name: String) -> Never {
        DispatchQueue.global().async {
            do {
                let directory = MachineSSHKey.directory.appendingPathComponent(name, isDirectory: true)
                _ = try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let clone = Process()
                clone.executableURL = URL(fileURLWithPath: "/bin/cp")
                clone.arguments = ["-c", MachineSSHKey.baseImageURL.path, directory.appendingPathComponent("disk.img").path]
                try clone.run()
                clone.waitUntilExit()
                guard clone.terminationStatus == 0 else {
                    throw DockzError.socketSetupFailed("clone failed")
                }
                let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("disk.img"))
                try handle.truncate(atOffset: 16 * 1024 * 1024 * 1024)
                try handle.close()

                var settings = DockzSettings()
                settings.cpuCount = 2
                settings.memoryGiB = 1
                settings.enableRosetta = false
                let paths = DockzPaths(baseDirectory: directory)
                settings.save(to: paths)

                print("machines: booting \(name)…")
                let controller = VMController(paths: paths, settings: settings)
                let booted = DispatchSemaphore(value: 0)
                controller.onStateChange = { state in
                    if state == .running { booted.signal() }
                    if case .failed(let message) = state {
                        print("machines: boot FAILED — \(message)")
                        exit(1)
                    }
                }
                controller.start()
                guard booted.wait(timeout: .now() + 60) == .success else {
                    throw DockzError.socketSetupFailed("boot timeout")
                }

                var ip: String?
                for _ in 0..<20 where ip == nil {
                    let got = DispatchSemaphore(value: 0)
                    GuestIPResolver.fetch(connect: controller.vsockConnector()) { found in
                        ip = found
                        got.signal()
                    }
                    got.wait()
                    if ip == nil { Thread.sleep(forTimeInterval: 2) }
                }
                guard let ip else { throw DockzError.socketSetupFailed("no IP") }
                print("machines: \(name) is up at \(ip), diagnostics…")

                let diagnosed = DispatchSemaphore(value: 0)
                GuestShellRunner.run(
                    script: """
                    rc-service sshd status || true
                    ls -la /root/.ssh 2>&1 | head -4
                    head -c 60 /root/.ssh/authorized_keys 2>&1; echo
                    netstat -tln 2>/dev/null | grep :22 || echo "port22-not-listening"
                    tail -3 /var/log/messages 2>/dev/null | grep -i ssh || true
                    """,
                    connect: controller.vsockConnector()
                ) { output in
                    print("--- guest diagnostics ---\n\(output ?? "(none)")\n---")
                    diagnosed.signal()
                }
                diagnosed.wait()
                print("machines: testing ssh…")

                let ssh = Process()
                ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                ssh.arguments = [
                    "-i", MachineSSHKey.privateKeyURL.path,
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "ConnectTimeout=10",
                    "root@\(ip)", "uname -a && echo SSH-WORKS",
                ]
                let output = Pipe()
                ssh.standardOutput = output
                ssh.standardError = FileHandle.nullDevice
                try ssh.run()
                ssh.waitUntilExit()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                print(text.trimmingCharacters(in: .whitespacesAndNewlines))

                let stopped = DispatchSemaphore(value: 0)
                controller.stop { stopped.signal() }
                _ = stopped.wait(timeout: .now() + 30)
                _ = try? FileManager.default.removeItem(at: directory)

                if text.contains("SSH-WORKS") {
                    print("MACHINE SMOKE OK")
                    exit(0)
                }
                print("MACHINE SMOKE FAILED (no ssh output)")
                exit(1)
            } catch {
                print("machines: smoke FAILED — \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }
}
