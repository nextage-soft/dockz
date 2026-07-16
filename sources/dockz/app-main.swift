import AppKit

@main
@MainActor
enum DockzMain {
    private static let delegate = AppDelegate()

    static func main() {
        // Writes to sockets that peers closed must not kill the process.
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        if arguments.contains("build-image") {
            ImageBuilderCLI.run(force: arguments.contains("--force"))
        }
        if arguments.contains("selftest-edit") {
            EditSelftest.run()
        }
        if arguments.contains("test") {
            TestRunner.run()
        }
        if arguments.contains("build-machine-base") {
            MachineCLI.runBuildBase()
        }
        if let index = arguments.firstIndex(of: "machine-smoke") {
            MachineCLI.runSmoke(name: arguments.indices.contains(index + 1) ? arguments[index + 1] : "smoke-test")
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
