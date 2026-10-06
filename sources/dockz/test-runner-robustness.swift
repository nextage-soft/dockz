import Foundation

/// Regression checks for failure classes found while shooting the docs:
/// over-long socket paths, two owners of one data folder, start failures
/// retried as crashes, and Monitor's warm-up state.
extension TestRunner {
    static func robustness() {
        // Socket path limit: 103 bytes, reported in words, applied to every
        // socket of a data root before it is chosen.
        expectEqual(UnixSocketPath.maxBytes, 103, "socket path: macOS limit is 103 bytes")
        expect(UnixSocketPath.problem("/tmp/dz/docker.sock") == nil, "socket path: short path accepted")
        let deep = "/private/tmp/" + String(repeating: "nested-folder/", count: 7) + "docker.sock"
        expect(UnixSocketPath.problem(deep)?.contains("at most 103") == true, "socket path: long path explained")
        let deepRoot = URL(fileURLWithPath: "/private/tmp/" + String(repeating: "nested-folder/", count: 6))
        expectEqual(UnixSocketPath.problems(inDataRoot: deepRoot).count, 2,
                    "socket path: data root checks docker.sock and debug-shell.sock")
        expect(UnixSocketPath.problems(inDataRoot: URL(fileURLWithPath: "/Users/me/.dockz")).isEmpty,
               "socket path: default data root fits")
        do {
            _ = try UnixSocketConnector.open(path: deep)
            expect(false, "socket path: connector refuses a long path")
        } catch {
            expect(error.localizedDescription.contains("at most 103"), "socket path: connector gives the reason")
        }

        // One owner per data folder: a second lock on the same folder fails
        // (flock conflicts across file descriptors, even in one process) and
        // the lock is released when its holder goes away.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dockz-lock-\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var first: DataRootLock? = try? DataRootLock.acquire(root: root).get()
        expect(first != nil, "data lock: first owner gets it")
        if case .failure(.heldByAnotherProcess(let pid)) = DataRootLock.acquire(root: root) {
            expectEqual(pid, getpid(), "data lock: second owner refused, told the holder's PID")
        } else {
            expect(false, "data lock: second owner refused")
        }
        first = nil
        expect((try? DataRootLock.acquire(root: root).get()) != nil, "data lock: free again once released")

        // A VM that never ran is reported, not restarted; one that ran and
        // stopped on its own is restarted; a requested stop is neither.
        expectEqual(VMRestartPolicy.classify(stopWasRequested: false, reachedRunning: false), .failedToStart,
                    "vm stop: failure before running is not retried")
        expectEqual(VMRestartPolicy.classify(stopWasRequested: false, reachedRunning: true), .crashed,
                    "vm stop: stop while running is a crash")
        expectEqual(VMRestartPolicy.classify(stopWasRequested: true, reachedRunning: true), .requested,
                    "vm stop: requested stop")

        // Monitor asks for the disk breakdown on every tick until it has one,
        // one request at a time, then every tenth tick.
        expect(MonitorStore.shouldSampleBreakdown(tick: 3, haveBreakdown: false, inFlight: false),
               "monitor: no breakdown yet → ask now")
        expect(!MonitorStore.shouldSampleBreakdown(tick: 3, haveBreakdown: false, inFlight: true),
               "monitor: never two requests at once")
        expect(!MonitorStore.shouldSampleBreakdown(tick: 3, haveBreakdown: true, inFlight: false),
               "monitor: have one → wait for the period")
        expect(MonitorStore.shouldSampleBreakdown(tick: 10, haveBreakdown: true, inFlight: false),
               "monitor: refresh every tenth tick")
    }
}
