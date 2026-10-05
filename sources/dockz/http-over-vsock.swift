import Foundation
import Virtualization

/// One HTTP/1.1 exchange over an open byte stream (vsock, SSH, TLS or unix
/// socket), implemented with plain blocking reads on a dedicated thread. Each
/// Docker Engine API call opens its own stream, `Connection: close` semantics.
final class RawHTTPCall {
    struct Response {
        let status: Int
        let body: Data
    }

    /// Idle limit for request/response calls: a remote engine or link that
    /// stops answering must fail the call instead of parking a thread forever.
    /// Streams (/events) are open-ended and have no limit.
    static let responseIdleTimeout: TimeInterval = 120

    private let connection: DockerByteStream
    /// Guards the descriptor's lifetime: `cancel()` may only touch it while
    /// the reader thread has not closed it (the number could be reused).
    private let lifecycle = NSLock()
    private var finished = false

    init(stream: DockerByteStream) {
        self.connection = stream
    }

    /// Ends an open-ended stream from any thread. The reader sees EOF, then
    /// closes the connection and fires `onClose` itself.
    func cancel() {
        lifecycle.lock()
        if !finished { shutdown(connection.fileDescriptor, SHUT_RDWR) }
        lifecycle.unlock()
    }

    private func finishAndClose() {
        lifecycle.lock()
        finished = true
        lifecycle.unlock()
        connection.close()
    }

    func get(path: String, completion: @escaping (Result<Response, Error>) -> Void) {
        run(method: "GET", path: path, body: nil, headers: [:], onBodyData: nil, completion: completion, onClose: nil)
    }

    func request(method: String, path: String, body: Data? = nil, headers: [String: String] = [:], completion: @escaping (Result<Response, Error>) -> Void) {
        run(method: method, path: path, body: body, headers: headers, onBodyData: nil, completion: completion, onClose: nil)
    }

    /// Long-lived streaming GET (e.g. /events). `onBodyData` fires for every
    /// decoded payload piece; `onClose` fires when the stream ends.
    func stream(path: String, onBodyData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        run(method: "GET", path: path, body: nil, headers: [:], onBodyData: onBodyData, completion: nil, onClose: onClose)
    }

    private func run(
        method: String,
        path: String,
        body: Data?,
        headers customHeaders: [String: String],
        onBodyData: ((Data) -> Void)?,
        completion: ((Result<Response, Error>) -> Void)?,
        onClose: (() -> Void)?
    ) {
        let connection = self.connection
        Thread.detachNewThread { [self] in
            let fd = connection.fileDescriptor
            var noSigpipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            if onBodyData == nil {
                var timeout = timeval(tv_sec: Int(Self.responseIdleTimeout), tv_usec: 0)
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            }

            var extraHeaders = ""
            for (name, value) in customHeaders {
                extraHeaders += "\(name): \(value)\r\n"
            }
            if method != "GET" || body != nil {
                extraHeaders += "Content-Length: \(body?.count ?? 0)\r\n"
            }
            if body != nil {
                extraHeaders += "Content-Type: application/json\r\n"
            }
            let request = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nAccept: */*\r\n\(extraHeaders)Connection: close\r\n\r\n"
            var requestBytes = Array(request.utf8)
            if let body { requestBytes.append(contentsOf: body) }
            let written = requestBytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == requestBytes.count else {
                let reason = connection.failureDiagnostics() ?? "request write failed"
                finishAndClose()
                completion?(.failure(DockzError.httpProtocolError(reason)))
                onClose?()
                return
            }

            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var received = Data()
            var headers: [String: String] = [:]
            var status = 0
            var headersParsed = false
            var chunked = false
            var contentLength: Int?
            var body = Data()
            let chunkDecoder = ChunkedDecoder()

            func deliver(_ payload: Data) {
                guard !payload.isEmpty else { return }
                if let onBodyData { onBodyData(payload) } else { body.append(payload) }
            }

            readLoop: while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                received.append(contentsOf: buffer[0..<count])

                if !headersParsed {
                    guard let headerEnd = received.range(of: Data("\r\n\r\n".utf8)) else { continue }
                    let headerData = received.subdata(in: received.startIndex..<headerEnd.lowerBound)
                    received.removeSubrange(received.startIndex..<headerEnd.upperBound)
                    let lines = String(data: headerData, encoding: .utf8)?.components(separatedBy: "\r\n") ?? []
                    if let statusLine = lines.first {
                        let parts = statusLine.split(separator: " ")
                        if parts.count >= 2 { status = Int(parts[1]) ?? 0 }
                    }
                    for line in lines.dropFirst() {
                        guard let colon = line.firstIndex(of: ":") else { continue }
                        let name = line[..<colon].lowercased()
                        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[name] = value
                    }
                    chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
                    contentLength = headers["content-length"].flatMap { Int($0) }
                    headersParsed = true
                }

                if headersParsed && !received.isEmpty {
                    if chunked {
                        deliver(chunkDecoder.feed(received))
                        received.removeAll(keepingCapacity: true)
                        if chunkDecoder.isDone { break readLoop }
                    } else {
                        deliver(received)
                        received.removeAll(keepingCapacity: true)
                    }
                }
                if let contentLength, !chunked, body.count >= contentLength { break }
            }

            // Ask the transport why before closing it tears that state down.
            let diagnostics = headersParsed ? nil : connection.failureDiagnostics()
            finishAndClose()
            if let completion {
                if headersParsed {
                    completion(.success(Response(status: status, body: body)))
                } else {
                    completion(.failure(DockzError.httpProtocolError(diagnostics ?? "connection closed before response")))
                }
            }
            onClose?()
        }
    }
}
