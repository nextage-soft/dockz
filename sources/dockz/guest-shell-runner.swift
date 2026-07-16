import Foundation
import Virtualization

/// Runs a shell script inside the guest over the vsock debug shell (port
/// 2378, socat EXEC:/bin/sh). The script is base64-encoded to survive the
/// interactive shell, and its output is fenced with markers so prompt noise
/// can be stripped.
enum GuestShellRunner {
    static let shellVsockPort: UInt32 = 2378
    private static let beginMarker = "__DOCKZ_BEGIN__"
    private static let endMarker = "__DOCKZ_END__"

    static func run(
        script: String,
        connect: @escaping DockerAPIClient.VsockConnect,
        completion: @escaping (String?) -> Void
    ) {
        let fenced = "echo \(beginMarker)\n\(script)\necho \(endMarker)\n"
        let encoded = Data(fenced.utf8).base64EncodedString()
        connect(shellVsockPort) { result in
            guard case .success(let connection) = result else {
                completion(nil)
                return
            }
            Thread.detachNewThread {
                let fd = connection.fileDescriptor
                let command = "echo \(encoded) | base64 -d | /bin/sh 2>&1; exit\n"
                _ = Array(command.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    let count = read(fd, &buffer, buffer.count)
                    if count <= 0 { break }
                    collected.append(contentsOf: buffer[0..<count])
                    if collected.count > 4 * 1024 * 1024 { break }
                }
                connection.close()

                let text = String(decoding: collected, as: UTF8.self)
                guard let beginRange = text.range(of: beginMarker),
                      let endRange = text.range(of: endMarker, range: beginRange.upperBound..<text.endIndex) else {
                    completion(nil)
                    return
                }
                let payload = text[beginRange.upperBound..<endRange.lowerBound]
                completion(payload.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
