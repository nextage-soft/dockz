import Foundation

/// Bidirectional byte pump between two file descriptors using blocking IO on
/// two dedicated threads. EOF on one side half-closes the other (shutdown),
/// and `onClose` fires exactly once when both directions have finished.
/// FDBridge does not close the descriptors itself — the owner does that in
/// `onClose` (the vsock side is owned by its VZVirtioSocketConnection).
final class FDBridge {
    private let lock = NSLock()
    private var finishedDirections = 0
    private let onClose: () -> Void

    init(firstFD: Int32, secondFD: Int32, onClose: @escaping () -> Void) {
        self.onClose = onClose
        // Sockets accepted from a non-blocking listener inherit O_NONBLOCK on
        // macOS; the copy loops use blocking IO, and a spurious EAGAIN would
        // read as EOF and half-close the peer mid-request.
        Self.makeBlocking(firstFD)
        Self.makeBlocking(secondFD)
        Self.disableSIGPIPE(firstFD)
        Self.disableSIGPIPE(secondFD)
        Thread.detachNewThread { [self] in copyLoop(from: firstFD, to: secondFD) }
        Thread.detachNewThread { [self] in copyLoop(from: secondFD, to: firstFD) }
    }

    private func copyLoop(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        outer: while true {
            let bytesRead = Self.readRetrying(source, &buffer)
            if bytesRead <= 0 { break }
            var offset = 0
            while offset < bytesRead {
                // Pointer arithmetic on the real storage — `&buffer[offset]`
                // would pass a one-byte temporary and write stack garbage.
                let written = buffer.withUnsafeBytes { raw in
                    write(destination, raw.baseAddress!.advanced(by: offset), bytesRead - offset)
                }
                if written <= 0 {
                    if errno == EINTR { continue }
                    break outer
                }
                offset += written
            }
        }
        shutdown(destination, SHUT_WR)
        finishDirection()
    }

    private func finishDirection() {
        lock.lock()
        finishedDirections += 1
        let done = finishedDirections == 2
        lock.unlock()
        if done { onClose() }
    }

    private static func readRetrying(_ fd: Int32, _ buffer: inout [UInt8]) -> Int {
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == -1 && errno == EINTR { continue }
            return count
        }
    }

    private static func makeBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 && (flags & O_NONBLOCK) != 0 {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
    }

    private static func disableSIGPIPE(_ fd: Int32) {
        var value: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
}
