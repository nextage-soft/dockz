import Foundation

extension FileHandle {
    /// Delivers what arrives on this handle, chunk by chunk, until end of
    /// file, then removes the handler and calls `onEnd`.
    ///
    /// The one way DockZ reads pipes and consoles asynchronously. A handle at
    /// end of file stays "readable" forever and `availableData` returns empty
    /// data each time, so a readabilityHandler that only skips empty chunks
    /// keeps being called in a tight loop. Seen 2026-10-07: DockZ held ~75% of
    /// a CPU core for hours after a disk shrink, because SerialExpect's handler
    /// stayed installed on the builder VM's console after the VM powered off.
    func readChunks(_ onData: @escaping (Data) -> Void, onEnd: (() -> Void)? = nil) {
        readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                onEnd?()
                return
            }
            onData(data)
        }
    }
}
