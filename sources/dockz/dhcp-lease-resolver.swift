import Foundation

/// Resolves a machine's IP from the macOS vmnet DHCP lease database by MAC
/// address. Cloud-image guests (Debian/Ubuntu) have no vsock agent, so this is
/// how DockZ learns their address — the same mechanism Docker/Lima/Vagrant use.
enum DHCPLeaseResolver {
    private static let leasesPath = "/var/db/dhcpd_leases"

    /// Normalises "0a:1b:0c:..." → "a:1b:c:..." because the lease file drops
    /// leading zeros in each octet.
    private static func normalize(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { octet -> String in
            let trimmed = String(octet.drop { $0 == "0" })
            return trimmed.isEmpty ? "0" : trimmed
        }.joined(separator: ":")
    }

    static func ip(forMAC mac: String) -> String? {
        guard let content = try? String(contentsOfFile: leasesPath, encoding: .utf8) else { return nil }
        return parse(leases: content, forMAC: mac)
    }

    /// Parses lease-file contents (extracted for testability).
    static func parse(leases content: String, forMAC mac: String) -> String? {
        let wanted = normalize(mac)
        var currentIP: String?
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" { currentIP = nil }
            if line.hasPrefix("ip_address=") {
                currentIP = String(line.dropFirst("ip_address=".count))
            }
            if line.hasPrefix("hw_address=") {
                // format: hw_address=1,a:1b:c:...
                let value = String(line.dropFirst("hw_address=".count))
                let mac = value.contains(",") ? String(value.split(separator: ",").last ?? "") : value
                if normalize(mac) == wanted, let ip = currentIP {
                    return ip
                }
            }
        }
        return nil
    }

    /// Polls the lease file until the MAC appears (cloud-init boots take longer).
    static func waitForIP(mac: String, attempts: Int = 40, interval: TimeInterval = 2, completion: @escaping (String?) -> Void) {
        func attempt(_ n: Int) {
            if let ip = ip(forMAC: mac) {
                completion(ip)
                return
            }
            guard n < attempts else {
                completion(nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + interval) { attempt(n + 1) }
        }
        attempt(0)
    }
}
