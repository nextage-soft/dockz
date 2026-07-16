import Foundation

/// Append-only host-side diagnostics at `<data>/host.log`. NSLog output from a
/// hand-bundled app is hard to retrieve (unified log filters it), and the VM
/// lifecycle bugs worth logging are exactly the ones where the app can no
/// longer tell the user what happened — so keep our own file.
enum HostLog {
    private static let queue = DispatchQueue(label: "com.nextagesoft.dockz.hostlog")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        NSLog("dockz: %@", message)
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            let url = DockzPaths().baseDirectory.appendingPathComponent("host.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
