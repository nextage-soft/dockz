import Foundation

/// Sets the VM's time zone. The Alpine guest ships without tzdata, but macOS
/// zoneinfo files are the same TZif format Linux reads, so the host's own file
/// is copied into the guest's /etc/localtime over the vsock shell — no network
/// or package install involved. Affects the VM (its shell, dockerd logs);
/// containers keep their own /etc/localtime and TZ as usual.
enum GuestTimeZone {
    /// Host zoneinfo root (a symlink to /var/db/timezone/zoneinfo on macOS).
    static let zoneinfoRoot = URL(fileURLWithPath: "/usr/share/zoneinfo")

    /// Empty setting = follow this Mac.
    static func effectiveIdentifier(setting: String) -> String {
        setting.isEmpty ? TimeZone.current.identifier : setting
    }

    /// Only identifiers macOS itself knows are accepted — this is also what
    /// keeps the value safe to embed in a path and a shell script.
    static func isValid(_ identifier: String) -> Bool {
        TimeZone.knownTimeZoneIdentifiers.contains(identifier)
    }

    /// TZif bytes for `identifier`, or nil if unknown / not a TZif file.
    static func zoneData(for identifier: String) -> Data? {
        guard isValid(identifier),
              let data = try? Data(contentsOf: zoneinfoRoot.appendingPathComponent(identifier)),
              data.starts(with: Data("TZif".utf8)) else { return nil }
        return data
    }

    /// Guest script installing the zone. /etc/localtime may be a dangling
    /// symlink into a zoneinfo tree the guest doesn't have, so it is removed
    /// before the new file is written.
    static func installScript(identifier: String, zoneData: Data) -> String {
        """
        rm -f /etc/localtime
        echo '\(zoneData.base64EncodedString())' | base64 -d > /etc/localtime
        echo '\(identifier)' > /etc/timezone
        echo "DOCKZ-TZ $(date +%Z%z)"
        """
    }

    /// Pushes the zone into a running guest. `completion` gets an error text,
    /// or nil on success.
    static func apply(setting: String,
                      connect: @escaping DockerAPIClient.VsockConnect,
                      completion: @escaping (String?) -> Void) {
        let identifier = effectiveIdentifier(setting: setting)
        guard let data = zoneData(for: identifier) else {
            completion("Unknown time zone \(identifier)")
            return
        }
        GuestShellRunner.run(script: installScript(identifier: identifier, zoneData: data),
                             connect: connect) { output in
            let applied = output?.contains("DOCKZ-TZ") ?? false
            if applied { NSLog("dockz: guest time zone set to %@", identifier) }
            completion(applied ? nil : "Could not reach the VM to set its time zone")
        }
    }
}
