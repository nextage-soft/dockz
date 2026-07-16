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
    /// Emitted once per complete console line, so callers can surface live
    /// output instead of only the log file. Called on the reader's queue.
    private let onLine: ((String) -> Void)?
    private var lineBuffer = ""

    init(readHandle: FileHandle, writeHandle: FileHandle, logURL: URL,
         onLine: ((String) -> Void)? = nil) {
        self.writeHandle = writeHandle
        self.onLine = onLine
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
            self.emitLines(from: text)
        }
    }

    /// Splits the stream into lines. Serial consoles use \r\n and redraw
    /// progress bars with bare \r, so treat both as terminators and drop blanks.
    /// Swift groups "\r\n" into a single Character, so it must be matched as a
    /// third case — comparing against "\n"/"\r" alone never finds a CRLF.
    /// apk/openrc paint with ANSI escapes, so each line is sanitized first.
    private func emitLines(from text: String) {
        guard let onLine else { return }
        lineBuffer += text
        while let index = lineBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let raw = String(lineBuffer[lineBuffer.startIndex..<index])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: index)...])
            let line = Self.sanitize(raw)
            if !line.isEmpty { onLine(line) }
        }
        // A very long line without a terminator must not grow without bound.
        if lineBuffer.count > 4096 { lineBuffer = String(lineBuffer.suffix(1024)) }
    }

    /// Strips ANSI/VT escape sequences and other control bytes so the console
    /// stream is human-readable (apk and OpenRC draw progress with CSI codes,
    /// bare ESC 7/8 cursor save-restore, and \b backspaces).
    static func sanitize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.unicodeScalars.makeIterator()

        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else {
                // Keep printable characters and tabs; drop other control bytes.
                if scalar == "\t" || scalar.value >= 0x20 { result.unicodeScalars.append(scalar) }
                continue
            }
            guard let marker = iterator.next() else { break }
            if marker == "[" {
                // CSI: consume until a final byte in the 0x40–0x7E range.
                while let byte = iterator.next(), !(byte.value >= 0x40 && byte.value <= 0x7E) {}
            }
            // Two-byte escapes (ESC 7, ESC 8, ESC =, …) need nothing more consumed.
        }
        return result.trimmingCharacters(in: .whitespaces)
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
