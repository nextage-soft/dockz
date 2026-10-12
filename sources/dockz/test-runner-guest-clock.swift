import Foundation

/// Guest clocks fell days behind after the Mac slept (VMs are frozen during
/// sleep and nothing set the time again). These check the sync script's
/// decision, its markers, and that new images enable ntpd.
extension TestRunner {
    static func guestClock() {
        // The guest script's comparison, run in a real shell with `date`
        // faked: guest at 1000, host at the given epoch.
        func run(hostEpoch: Int) -> String {
            let fakeDate = #"date() { if [ "$1" = "+%s" ]; then echo 1000; else echo "SET-TO $3"; fi; }"#
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", fakeDate + "\n" + GuestClockSync.script(hostEpoch: hostEpoch)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        expectEqual(GuestClockSync.parse(run(hostEpoch: 1001)), .inSync(offset: 1), "clock: 1 s off is left alone")
        expectEqual(GuestClockSync.parse(run(hostEpoch: 998)), .inSync(offset: -2), "clock: tolerance applies both ways")
        expectEqual(GuestClockSync.parse(run(hostEpoch: 1000 + 2 * 86_400)), .corrected(offset: 172_800),
                    "clock: guest 2 days behind is set")
        expectEqual(GuestClockSync.parse(run(hostEpoch: 900)), .corrected(offset: -100), "clock: guest ahead is set too")
        expect(GuestClockSync.script(hostEpoch: 1_791_780_524).contains(#"date -u -s "@$h""#),
               "clock: sets UTC from the host epoch")

        // Markers among other console output; garbage is not an outcome.
        expectEqual(GuestClockSync.parse("noise\nDOCKZ-CLOCK-SET 39600\r\n"), .corrected(offset: 39_600),
                    "clock: marker found in output")
        expect(GuestClockSync.parse("DOCKZ-CLOCK-SET\nhello") == nil, "clock: malformed marker ignored")

        expectEqual(GuestClockSync.describe(2 * 86_400 + 3 * 3600), "2 d 3 h behind", "clock: days")
        expectEqual(GuestClockSync.describe(11 * 3600 + 5 * 60), "11 h 5 min behind", "clock: hours")
        expectEqual(GuestClockSync.describe(-40), "40 s ahead", "clock: ahead")

        // The guest keeps itself right while DockZ is not running the sync:
        // every image build path enables ntpd, and the sync enables it on
        // images built before that.
        expect(GuestClockSync.script(hostEpoch: 0).contains("rc-update add ntpd default"),
               "clock: sync enables ntpd on older images")
        if let guest = ImageBuilderCLI.locateGuestDirectory() {
            for file in ["provision-inside-vm.sh", "Dockerfile"] {
                let text = (try? String(contentsOf: guest.appendingPathComponent(file), encoding: .utf8)) ?? ""
                let defaultLines = text.split(separator: "\n").filter { $0.contains("rc-update add") && $0.contains("default") }
                expect(!defaultLines.isEmpty && defaultLines.allSatisfy { $0.contains("ntpd") },
                       "clock: \(file) enables ntpd in every profile")
            }
        } else {
            expect(false, "clock: guest/ directory found")
        }
    }
}
