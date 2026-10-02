import Foundation

/// Recovery from a wedged guest (see vm-supervisor.swift) and the stream
/// plumbing that cut per-sample vsock connections.
extension TestRunner {
    static func vmSupervisor() {
        // Crash-loop limit: 3 restarts per 10 minutes.
        var policy = VMRestartPolicy()
        expect(policy.allowRestart(at: 0) && policy.allowRestart(at: 60) && policy.allowRestart(at: 120),
               "restart: first three allowed")
        expect(!policy.allowRestart(at: 180), "restart: fourth within 10 min refused")
        expect(policy.allowRestart(at: 700), "restart: allowed again once the window passes")

        // Unresponsive = 4 failures in a row AND 60 s of awake time.
        var health = EngineHealthTracker(now: 1000)
        expect(!health.record(success: false, at: 1015) && !health.record(success: false, at: 1030)
               && !health.record(success: false, at: 1045), "health: early failures tolerated")
        expect(health.record(success: false, at: 1060), "health: 4 failures over 60 s → dead")
        var flaky = EngineHealthTracker(now: 0)
        _ = flaky.record(success: false, at: 15)
        _ = flaky.record(success: false, at: 30)
        _ = flaky.record(success: true, at: 45)
        expect(!flaky.record(success: false, at: 60), "health: a success resets the count")
        var slept = EngineHealthTracker(now: 0)
        expect(!slept.record(success: false, at: 3600), "health: one failure after a long gap isn't enough")

        expect(GuestKernelGuard.script.contains("kernel.panic_on_oops=1")
               && GuestKernelGuard.script.contains("kernel.softlockup_panic=1")
               && GuestKernelGuard.script.contains("kernel.panic=\(GuestKernelGuard.rebootDelaySeconds)"),
               "kernel guard: panic on oops / soft lockup, then reboot")

        // console.log keeps the previous boots.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockz-console-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("console.log")
        for boot in 1...7 {
            try? "boot \(boot)".write(to: log, atomically: true, encoding: .utf8)
            ConsoleLogRotation.rotate(log)
        }
        let kept = (1...6).map { index -> String in
            (try? String(contentsOf: root.appendingPathComponent("console.\(index).log"), encoding: .utf8)) ?? "-"
        }
        expectEqual(kept, ["boot 7", "boot 6", "boot 5", "boot 4", "-", "-"],
                    "console: newest first, \(ConsoleLogRotation.keep - 1) previous boots kept")

        // Newline-delimited JSON split across arbitrary chunks.
        var splitter = JSONLineSplitter()
        let first = splitter.feed(Data(#"{"a":1}"#.utf8) + Data("\n{\"b\":".utf8))
        let second = splitter.feed(Data("2}\n".utf8))
        expectEqual(first.count, 1, "ndjson: complete line parsed")
        expectEqual(second.first?["b"] as? Int, 2, "ndjson: object split across chunks parsed")

        // A handle cancelled before its connection opened never starts it.
        let early = DockerStreamHandle()
        early.cancel()
        expect(early.isCancelled, "stream: cancel before open")

        // cancel() ends a live stream that the server would keep open forever.
        guard let pair = try? SocketPair.make() else { return expect(false, "stream: socketpair") }
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(pair.remote, &buffer, buffer.count)   // the request
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"n\":1}\n"
            _ = head.withCString { write(pair.remote, $0, strlen($0)) }
            _ = read(pair.remote, &buffer, buffer.count)   // blocks until the client goes away
            Darwin.close(pair.remote)
        }
        let call = RawHTTPCall(stream: FileDescriptorStream(fileDescriptor: pair.local))
        let gotSample = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        var lines = JSONLineSplitter()
        call.stream(path: "/containers/x/stats?stream=true",
                    onBodyData: { data in if !lines.feed(data).isEmpty { gotSample.signal() } },
                    onClose: { closed.signal() })
        expect(gotSample.wait(timeout: .now() + 2) == .success, "stream: sample delivered")
        call.cancel()
        expect(closed.wait(timeout: .now() + 2) == .success, "stream: cancel() ends an open stream")
        call.cancel()   // after close: must be a no-op, never touching a reused fd
    }
}
