import Foundation

/// Guest files baked into disk.img must not stay broken after the app fixes
/// them, and no vsock relay may cut a stream short after a half-close.
extension TestRunner {
    static func guestSync() {
        guard let guest = ImageBuilderCLI.locateGuestDirectory() else {
            expect(false, "guest sync: guest/ directory found")
            return
        }
        let rootfs = guest.appendingPathComponent("rootfs", isDirectory: true)

        // Every socat relay keeps the other direction open after a
        // half-close (socat's default -t 0.5 dropped late `docker run` output).
        if let agent = try? String(contentsOf: rootfs.appendingPathComponent("etc/init.d/dockz-agent"), encoding: .utf8) {
            let relays = agent.split(separator: "\n").filter { $0.contains("/usr/bin/socat") }
            expect(!relays.isEmpty, "socat relays: found in dockz-agent")
            for relay in relays {
                expect(relay.contains("$RELAY_OPTS"), "socat relays: \(relay.trimmingCharacters(in: .whitespaces)) sets the timeout")
            }
            expect(agent.contains("RELAY_OPTS=\"-t "), "socat relays: timeout defined")
        } else {
            expect(false, "socat relays: dockz-agent readable")
        }

        // Which bundled files are synced live: services yes, boot path no.
        let files = GuestRootfsSync.bundledFiles(rootfs: rootfs)
        let paths = files.map(\.path)
        expect(paths.contains("etc/init.d/dockz-agent"), "guest sync: agent init script synced")
        expect(paths.contains("usr/local/bin/dockz-print-ip"), "guest sync: helper scripts synced")
        expect(!paths.contains { $0.hasPrefix("boot/") || $0 == "etc/fstab" || $0.hasPrefix("etc/network/") },
               "guest sync: boot-path files left alone")
        // Placeholders filled in at image build (e.g. @SHARE_PATH@ in fstab)
        // would be written raw by a live sync.
        for file in files where String(decoding: file.contents, as: UTF8.self)
            .range(of: "@[A-Z_]+@", options: .regularExpression) != nil {
            expect(false, "guest sync: \(file.path) has a build-time placeholder")
        }
        expect(files.first { $0.path == "etc/init.d/dockz-agent" }?.executable == true,
               "guest sync: init script stays executable")

        // The script replaces only changed files and restarts only services.
        let script = GuestRootfsSync.script(for: [
            .init(path: "etc/init.d/demo", contents: Data("a".utf8), executable: true),
            .init(path: "usr/local/bin/tool", contents: Data("b".utf8), executable: false),
        ])
        expect(script.contains("cmp -s '/etc/init.d/demo.dockz-sync' '/etc/init.d/demo'"), "guest sync: compares before replacing")
        expect(script.contains("changed_services=\"$changed_services demo\""), "guest sync: changed service restarts")
        expect(!script.contains("changed_services=\"$changed_services tool\""), "guest sync: plain files restart nothing")
        expect(script.contains("chmod 644 '/usr/local/bin/tool.dockz-sync'"), "guest sync: keeps file modes")

        expectEqual(GuestRootfsSync.changedPaths(fromOutput: "x\nDOCKZ-SYNC-CHANGED:etc/init.d/dockz-agent\r\nDOCKZ-SYNC-DONE\n"),
                    ["etc/init.d/dockz-agent"], "guest sync: changed paths read back")
        expectEqual(GuestRootfsSync.changedPaths(fromOutput: "DOCKZ-SYNC-DONE"), [], "guest sync: nothing changed")
        expect(GuestRootfsSync.changedPaths(fromOutput: "DOCKZ-SYNC-CHANGED:a") == nil, "guest sync: incomplete run noticed")
    }
}
