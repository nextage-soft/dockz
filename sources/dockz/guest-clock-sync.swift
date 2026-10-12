import Foundation

/// Keeps a guest's wall clock on the Mac's time.
///
/// A VM is frozen while the Mac sleeps, and nothing in the Alpine guest used
/// to set its clock again: the kernel reads the virtual RTC once at boot and
/// ntpd was not enabled. Sessions saw the Docker VM days behind after the Mac
/// slept (4 days on 2026-08-18, ~2 days on 2026-09-15, 11 h on 2026-09-23;
/// Postgres `now()` and TLS/S3 signatures wrong until DockZ restarted), and on
/// 2026-10-12 a VM that had run 108 h of wall time counted only 45.5 h of
/// uptime — 62 h frozen during sleep.
///
/// Two layers, so neither is a single point of failure:
/// - the host pushes its time over the vsock shell when the engine comes up,
///   when the Mac wakes, when its clock or zone changes, and every minute —
///   immediate and works offline;
/// - the same script enables the guest's own busybox ntpd, which keeps
///   correcting the clock while DockZ itself is hung or not responding.
enum GuestClockSync {
    enum Reason: String {
        case bringUp = "engine up"
        case wake = "Mac woke"
        case clockChanged = "Mac clock changed"
        case zoneChanged = "Mac time zone changed"
        case periodic = "periodic check"
    }

    /// Offsets up to this are left alone: the push itself (vsock round trip,
    /// whole-second epoch) is accurate only to about a second.
    static let toleranceSeconds = 2

    /// How often the periodic check runs. One tiny shell command per VM; a
    /// minute bounds how long a missed wake can leave a clock wrong.
    static let periodicInterval: TimeInterval = 60

    static let setMarker = "DOCKZ-CLOCK-SET"
    static let okMarker = "DOCKZ-CLOCK-OK"

    /// Guest script: step the clock when it is off by more than the
    /// tolerance, report the offset, and make sure ntpd is enabled and running
    /// (idempotent; images built before ntpd was enabled pick it up here).
    static func script(hostEpoch: Int) -> String {
        """
        h=\(hostEpoch); g=$(date +%s); d=$((h - g)); a=${d#-}
        if [ "$a" -gt \(toleranceSeconds) ]; then
            date -u -s "@$h" >/dev/null && echo "\(setMarker) $d"
        else
            echo "\(okMarker) $d"
        fi
        if [ -x /etc/init.d/ntpd ]; then
            rc-update add ntpd default >/dev/null 2>&1
            rc-service ntpd status >/dev/null 2>&1 || rc-service ntpd start >/dev/null 2>&1
        fi
        """
    }

    enum Outcome: Equatable {
        /// Clock was within tolerance; offset in seconds (host − guest).
        case inSync(offset: Int)
        /// Clock was stepped; offset it had before.
        case corrected(offset: Int)
    }

    static func parse(_ output: String) -> Outcome? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.count == 2, let offset = Int(parts[1]) else { continue }
            if parts[0] == setMarker { return .corrected(offset: offset) }
            if parts[0] == okMarker { return .inSync(offset: offset) }
        }
        return nil
    }

    /// "2 d 3 h behind" / "40 s ahead" — offset is host − guest.
    static func describe(_ offset: Int) -> String {
        let magnitude = abs(offset)
        let days = magnitude / 86_400, hours = magnitude % 86_400 / 3600, minutes = magnitude % 3600 / 60
        let amount: String
        if days > 0 { amount = "\(days) d \(hours) h" }
        else if hours > 0 { amount = "\(hours) h \(minutes) min" }
        else if minutes > 0 { amount = "\(minutes) min \(magnitude % 60) s" }
        else { amount = "\(magnitude) s" }
        return "\(amount) \(offset > 0 ? "behind" : "ahead")"
    }

    /// Runs one sync. `completion` gets nil when the guest could not be reached.
    static func sync(connect: @escaping DockerAPIClient.VsockConnect,
                     completion: @escaping (Outcome?) -> Void) {
        let epoch = Int(Date().timeIntervalSince1970.rounded())
        GuestShellRunner.run(script: script(hostEpoch: epoch), connect: connect) { output in
            completion(output.flatMap(parse))
        }
    }
}
