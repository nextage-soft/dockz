import Foundation
import Virtualization

/// One HTTP/1.1 GET exchange over an open vsock connection, implemented with
/// plain blocking reads on a dedicated thread. Used for the Docker Engine API
/// (each call opens its own vsock connection, `Connection: close` semantics).
final class RawHTTPCall {
    struct Response {
        let status: Int
        let body: Data
    }

    private let connection: VZVirtioSocketConnection

    init(connection: VZVirtioSocketConnection) {
        self.connection = connection
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
        Thread.detachNewThread {
            let fd = connection.fileDescriptor
            var noSigpipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

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
                connection.close()
                completion?(.failure(DockzError.httpProtocolError("request write failed")))
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

            connection.close()
            if let completion {
                if headersParsed {
                    completion(.success(Response(status: status, body: body)))
                } else {
                    completion(.failure(DockzError.httpProtocolError("connection closed before response")))
                }
            }
            onClose?()
        }
    }
}
