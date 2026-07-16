import Foundation

/// Tiny expect-style automation over a serial console exposed as FileHandles.
/// All received bytes are appended to a log file for debugging.
final class SerialExpect {
    enum ExpectError: LocalizedError {
        case timeout(waitingFor: String)

        var errorDescription: String? {
            if case .timeout(let pattern) = self {
                return "Timed out waiting for \"\(pattern)\" on the serial console (see build log)"
            }
            return nil
        }
    }

    private let writeHandle: FileHandle
    private let condition = NSCondition()
    private var buffer = ""
    private let logHandle: FileHandle?

    init(readHandle: FileHandle, writeHandle: FileHandle, logURL: URL) {
        self.writeHandle = writeHandle
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
        readHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.logHandle?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            self.condition.lock()
            self.buffer += text
            self.condition.broadcast()
            self.condition.unlock()
        }
    }

    /// Waits until any of the patterns appears in the console output.
    /// Consumes the buffer up to and including the first match.
    @discardableResult
    func expect(_ patterns: [String], timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            for pattern in patterns {
                if let range = buffer.range(of: pattern) {
                    let matched = pattern
                    buffer.removeSubrange(..<range.upperBound)
                    return matched
                }
            }
            guard Date() < deadline else {
                throw ExpectError.timeout(waitingFor: patterns.joined(separator: "\" or \""))
            }
            condition.wait(until: min(deadline, Date().addingTimeInterval(1)))
        }
    }

    func send(_ text: String) {
        writeHandle.write(Data(text.utf8))
    }

    func sendLine(_ text: String) {
        send(text + "\n")
    }
}
