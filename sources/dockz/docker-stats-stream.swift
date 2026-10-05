import Foundation

/// A long-lived Docker API stream the caller can end at any time, including
/// before its connection has finished opening.
final class DockerStreamHandle {
    private let lock = NSLock()
    private var call: RawHTTPCall?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Returns false when the handle was cancelled first; the caller then
    /// must not start the call.
    fileprivate func attach(_ call: RawHTTPCall) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.call = call
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let call = self.call
        lock.unlock()
        call?.cancel()
    }
}

/// Splits a byte stream of newline-delimited JSON (Docker's stats and events
/// streams) into complete objects, however the bytes were chunked.
struct JSONLineSplitter {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [[String: Any]] {
        pending.append(data)
        var objects: [[String: Any]] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                objects.append(object)
            }
        }
        return objects
    }
}

extension DockerAPIClient {
    /// Docker's own once-a-second stats stream for one container: one
    /// connection for as long as it is watched, instead of a fresh
    /// connection per sample.
    func streamContainerStats(id: String,
                              onSample: @escaping ([String: Any]) -> Void,
                              onClose: @escaping () -> Void) -> DockerStreamHandle {
        let handle = DockerStreamHandle()
        openStream { result in
            guard case .success(let connection) = result else { return onClose() }
            let call = RawHTTPCall(stream: connection)
            guard handle.attach(call) else {
                connection.close()
                return onClose()
            }
            var splitter = JSONLineSplitter()
            call.stream(
                path: "/containers/\(id)/stats?stream=true",
                onBodyData: { data in splitter.feed(data).forEach(onSample) },
                onClose: onClose
            )
        }
        return handle
    }
}

/// The Monitor's stats streams: one per running container, opened when a
/// container starts being watched and closed when it stops or the Monitor
/// closes. Latest sample per container is read on each tick.
final class ContainerStatsStreams {
    private let lock = NSLock()
    private var handles: [String: DockerStreamHandle] = [:]
    private var latest: [String: [String: Any]] = [:]

    /// Opens streams for new running containers, closes the rest.
    func sync(running ids: Set<String>, client: DockerAPIClient) {
        lock.lock()
        let stale = handles.filter { !ids.contains($0.key) }
        stale.keys.forEach { handles[$0] = nil; latest[$0] = nil }
        let missing = ids.filter { handles[$0] == nil }
        lock.unlock()
        stale.values.forEach { $0.cancel() }

        for id in missing {
            let handle = client.streamContainerStats(
                id: id,
                onSample: { [weak self] sample in self?.store(sample, for: id) },
                onClose: { [weak self] in self?.streamEnded(id) }
            )
            lock.lock()
            handles[id] = handle
            lock.unlock()
        }
    }

    func latestSample(for id: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return latest[id]
    }

    func stopAll() {
        lock.lock()
        let all = handles
        handles = [:]
        latest = [:]
        lock.unlock()
        all.values.forEach { $0.cancel() }
    }

    private func store(_ sample: [String: Any], for id: String) {
        lock.lock()
        if handles[id] != nil { latest[id] = sample }
        lock.unlock()
    }

    /// A stream that ended on its own (container stopped, engine restarted)
    /// is forgotten so the next sync reopens it if still needed.
    private func streamEnded(_ id: String) {
        lock.lock()
        if let handle = handles[id], !handle.isCancelled { handles[id] = nil }
        lock.unlock()
    }
}
