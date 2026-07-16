import AppKit
import SwiftUI

/// First-run setup for the guest disk image.
///
/// A fresh Mac has no `disk.img`, and the docker-based build script cannot help
/// there — needing a docker daemon to build the thing that provides the docker
/// daemon. So drive the netboot builder (Virtualization.framework only) straight
/// from the UI instead of sending the user to the command line.
@MainActor
final class GuestImageSetupModel: ObservableObject {
    enum State: Equatable {
        case idle
        case building
        case failed(String)
        case done
    }

    /// Console lines kept in memory. Enough to diagnose a failure without
    /// letting a chatty kernel log grow the view unbounded.
    private static let maxConsoleLines = 400

    @Published private(set) var state: State = .idle
    @Published private(set) var step = ""
    @Published private(set) var fraction = 0.0
    @Published private(set) var log: [String] = []
    @Published private(set) var console: [String] = []
    @Published private(set) var elapsed = 0
    /// Status of the parallel docker CLI download; empty when the Mac already
    /// has a `docker` binary and there is nothing to install.
    @Published private(set) var cliStatus = ""
    @Published private(set) var cliFailed = false

    private var imageDone = false
    private var cliDone = true

    /// Called on the main queue once the image exists.
    var onFinished: (() -> Void)?

    var isBuilding: Bool { state == .building }

    var elapsedText: String {
        String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    private var timer: Timer?

    func build() {
        guard state != .building else { return }
        state = .building
        step = "Starting…"
        fraction = 0
        log = []
        console = []
        elapsed = 0
        imageDone = false
        cliFailed = false
        startTimer()
        installCLIIfNeeded()

        let paths = DockzPaths()
        let sizeGB = max(DockzSettings.load(from: paths).diskLimitGB, 8)
        let request = ImageBuilderCLI.BuildRequest(
            outputURL: paths.diskImage,
            sizeGB: sizeGB,
            profile: "docker",
            publicKey: nil,
            progress: { [weak self] update in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.step = update.label
                    // Never let the bar go backwards, whatever order events land in.
                    self.fraction = max(self.fraction, update.fraction)
                    self.log.append(update.label)
                }
            },
            console: { [weak self] line in
                guard !Self.isNoise(line) else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.console.append(line)
                    if self.console.count > Self.maxConsoleLines {
                        self.console.removeFirst(self.console.count - Self.maxConsoleLines)
                    }
                }
            }
        )
        // buildDiskImage boots a VM and drives its serial console — blocking.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ImageBuilderCLI.buildDiskImage(request)
                DispatchQueue.main.async {
                    self.imageDone = true
                    self.maybeFinish()
                }
            } catch {
                DispatchQueue.main.async {
                    self.stopTimer()
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// First run on a Mac with no `docker` binary: fetch the CLI + compose in
    /// parallel with the image build and wire up the user's shell, so the whole
    /// onboarding is this one window. A failure here does not fail the setup —
    /// the engine runs fine without a CLI and Settings offers a retry.
    private func installCLIIfNeeded() {
        guard DockerCLI.resolve() == nil else {
            cliDone = true
            cliStatus = ""
            return
        }
        cliDone = false
        cliStatus = "Downloading the docker CLI + compose…"
        DockerCLIInstaller.install(
            progress: { [weak self] message in self?.cliStatus = "docker CLI: \(message)" },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    try? ShellIntegrationInstaller.install()
                    self.cliStatus = "docker CLI + compose installed · terminal set up"
                case .failure(let error):
                    self.cliFailed = true
                    self.cliStatus = "docker CLI install failed — \(error.localizedDescription) Retry later in Settings → Docker CLI."
                }
                self.cliDone = true
                self.maybeFinish()
            })
    }

    /// The window is done when both the image build and the CLI install have
    /// settled — whichever finishes last closes it out.
    private func maybeFinish() {
        guard state == .building, imageDone else { return }
        guard cliDone else {
            step = "Image ready — finishing the docker CLI download…"
            return
        }
        stopTimer()
        step = "Done."
        fraction = 1
        state = .done
        onFinished?()
    }

    /// Lines hidden from the on-screen console (the full transcript still goes
    /// to builder/build.log). The builder VM is throwaway, but "login: root" and
    /// the provision command echoing the user's home path read as alarming.
    private static let noiseMarkers = [
        "login:", "Welcome to Alpine", "wiki.alpinelinux.org",
        "You can setup the system", "You may change this message",
        "provision-inside-vm.sh", "SHARE_PATH=",
    ]

    static func isNoise(_ line: String) -> Bool {
        noiseMarkers.contains { line.contains($0) }
    }

    /// Copies the console transcript out, so a failed build can be reported.
    func copyConsole() {
        let text = (log + ["", "--- console ---"] + console).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .building else { return }
                self.elapsed += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

struct GuestImageSetupView: View {
    @ObservedObject var model: GuestImageSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up the DockZ engine").font(.title3.weight(.semibold))
                    Text("DockZ needs a small Alpine Linux VM to run the Docker engine.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            switch model.state {
            case .idle:
                idleBody
            case .building, .done:
                progressBody
            case .failed(let message):
                failureBody(message)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    label("Downloads Alpine Linux from dl-cdn.alpinelinux.org (~50 MB)",
                          "arrow.down.circle")
                    label("Builds the disk image in a temporary VM — nothing else is installed",
                          "cpu")
                    if DockerCLI.resolve() == nil {
                        label("Also installs the `docker` CLI + compose for your terminal (~50 MB)",
                              "terminal")
                    }
                    label("Takes a few minutes; needs an internet connection", "clock")
                }
                .padding(6)
            }
            Text("No Docker, Homebrew, or admin password required.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                Button("Build Engine Image") { model.build() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var progressBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: model.fraction)
                .progressViewStyle(.linear)
            HStack(spacing: 8) {
                if model.state == .done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(model.step)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(model.fraction * 100))% · \(model.elapsedText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !model.cliStatus.isEmpty {
                Label(model.cliStatus,
                      systemImage: model.cliFailed ? "exclamationmark.triangle.fill" : "terminal")
                    .font(.caption)
                    .foregroundStyle(model.cliFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            consoleView
            HStack {
                if model.state == .done {
                    Text("Starting the engine…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Keep DockZ open — this window closes itself when the image is ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Log") { model.copyConsole() }
                    .controlSize(.small)
            }
        }
    }

    private func failureBody(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Build failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            consoleView
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Button("Copy Log") { model.copyConsole() }
                Spacer()
                Button("Try Again") { model.build() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Live serial console. This is what shows the build is alive between the
    /// coarse steps, and the only diagnostic when it fails.
    private var consoleView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.console.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    if model.console.isEmpty {
                        Text("Waiting for the builder VM…")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(6)
            }
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .onChange(of: model.console.count) { count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private func label(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class GuestImageSetupWindowController {
    private var window: NSWindow?
    let model = GuestImageSetupModel()

    /// `onImageReady` fires as soon as the image exists (start the engine);
    /// `onDismiss` once this window has actually closed. They are separate so the
    /// owner only drops its reference in `onDismiss` — releasing the controller
    /// on `onImageReady` would deallocate it before the delayed close ran and
    /// strand the window on screen.
    func present(onImageReady: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        model.onFinished = { [weak self] in
            onImageReady()
            // Let the user read the final line before the window disappears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.close()
                onDismiss()
            }
        }
        if window == nil {
            let hosting = NSHostingController(rootView: GuestImageSetupView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "DockZ Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        bringToFront()
    }

    /// Shows the (possibly user-closed) window again without resetting state —
    /// a build that is still running keeps its progress.
    func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
        NSApp.setActivationPolicy(.accessory)
    }
}
