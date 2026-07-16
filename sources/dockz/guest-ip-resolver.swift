import Foundation
import Virtualization

/// Fetches the guest's eth0 IPv4 address via the vsock IP-report agent
/// (socat on port 2376 running a script that prints the address).
enum GuestIPResolver {
    static let ipReportVsockPort: UInt32 = 2376

    static func fetch(
        connect: @escaping DockerAPIClient.VsockConnect,
        completion: @escaping (String?) -> Void
    ) {
        connect(ipReportVsockPort) { result in
            guard case .success(let connection) = result else {
                completion(nil)
                return
            }
            Thread.detachNewThread {
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 256)
                while true {
                    let count = read(connection.fileDescriptor, &buffer, buffer.count)
                    if count <= 0 { break }
                    collected.append(contentsOf: buffer[0..<count])
                    if collected.count > 4096 { break }
                }
                connection.close()
                let text = String(data: collected, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                completion(isValidIPv4(text) ? text : nil)
            }
        }
    }

    private static func isValidIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }
}
