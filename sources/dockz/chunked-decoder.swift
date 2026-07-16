import Foundation

/// Incremental decoder for HTTP/1.1 chunked transfer encoding.
final class ChunkedDecoder {
    private enum Phase {
        case sizeLine
        case body(remaining: Int)
        case bodyCRLF
        case trailers
        case done
    }

    private var phase: Phase = .sizeLine
    private var buffer = Data()
    private(set) var isDone = false

    /// Feeds raw bytes from the wire and returns any decoded payload bytes.
    func feed(_ data: Data) -> Data {
        buffer.append(data)
        var output = Data()
        while true {
            switch phase {
            case .sizeLine:
                guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { return output }
                let line = String(data: buffer.subdata(in: buffer.startIndex..<lineEnd.lowerBound), encoding: .ascii) ?? ""
                buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
                let sizeText = line.split(separator: ";").first.map(String.init) ?? ""
                let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) ?? 0
                phase = size == 0 ? .trailers : .body(remaining: size)
            case .body(let remaining):
                if buffer.isEmpty { return output }
                let take = min(remaining, buffer.count)
                output.append(buffer.prefix(take))
                buffer.removeFirst(take)
                phase = take == remaining ? .bodyCRLF : .body(remaining: remaining - take)
            case .bodyCRLF:
                guard buffer.count >= 2 else { return output }
                buffer.removeFirst(2)
                phase = .sizeLine
            case .trailers:
                isDone = true
                phase = .done
                return output
            case .done:
                return output
            }
        }
    }
}
