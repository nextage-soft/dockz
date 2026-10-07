import Foundation

/// A handle at end of file must stop being watched: a readabilityHandler left
/// installed at EOF spins a CPU core (DockZ at ~75% CPU for hours after a
/// builder VM run).
extension TestRunner {
    static func chunkReader() {
        let pipe = Pipe()
        let lock = NSLock()
        var received = Data()
        let ended = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readChunks({ chunk in
            lock.lock(); received.append(chunk); lock.unlock()
        }, onEnd: { ended.signal() })
        pipe.fileHandleForWriting.write(Data("hello ".utf8))
        pipe.fileHandleForWriting.write(Data("world".utf8))
        try? pipe.fileHandleForWriting.close()
        expect(ended.wait(timeout: .now() + 3) == .success, "chunk reader: end of file reported")
        lock.lock(); let text = String(decoding: received, as: UTF8.self); lock.unlock()
        expectEqual(text, "hello world", "chunk reader: every chunk delivered")
        expect(pipe.fileHandleForReading.readabilityHandler == nil, "chunk reader: handler removed at end of file")

        // Every asynchronous read goes through readChunks; a hand-rolled
        // handler is how the spin came back.
        let sources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("sources/dockz", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)) ?? []
        expect(!files.isEmpty, "chunk reader: sources found (run from the repo root)")
        let handRolled = "readabilityHandler" + " = {"   // split so this file does not match
        for file in files where file.pathExtension == "swift" && file.lastPathComponent != "file-handle-chunk-reader.swift" {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            expect(!text.contains(handRolled), "chunk reader: \(file.lastPathComponent) uses readChunks")
        }
    }
}
