import AppKit
import SwiftUI

/// What quitting has to stop before DockZ may exit, and how far it got.
/// Every quit path (menu bar Quit, ⌘Q, Dock, logout/restart) goes through
/// applicationShouldTerminate, which builds this plan; the VMs then shut down
/// gracefully — up to ~15 s each before a forced stop — so the user sees what
/// is happening instead of an app that looks frozen.
struct ShutdownPlan: Equatable {
    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        var done = false
    }

    private(set) var steps: [Step]

    static let dockerStep = "docker"
    static let machinesStep = "machines"

    init(dockerRunning: Bool, runningMachines: [String]) {
        var steps: [Step] = []
        if dockerRunning {
            steps.append(Step(id: Self.dockerStep, title: "Stopping the Docker engine — containers shut down cleanly"))
        }
        if !runningMachines.isEmpty {
            let names = runningMachines.sorted().joined(separator: ", ")
            let noun = runningMachines.count == 1 ? "Linux machine" : "\(runningMachines.count) Linux machines"
            steps.append(Step(id: Self.machinesStep, title: "Stopping \(noun): \(names)"))
        }
        self.steps = steps
    }

    var isEmpty: Bool { steps.isEmpty }
    var allDone: Bool { steps.allSatisfy(\.done) }

    mutating func finish(_ id: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].done = true
    }
}

@MainActor
final class ShutdownProgress: ObservableObject {
    @Published private(set) var plan: ShutdownPlan

    init(plan: ShutdownPlan) { self.plan = plan }

    func finish(_ id: String) { plan.finish(id) }
}

private struct ShutdownView: View {
    @ObservedObject var progress: ShutdownProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shutting down DockZ…").font(.headline)
                    Text("Virtual machines are stopped safely so no data is lost. This can take a few seconds.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(progress.plan.steps) { step in
                    HStack(spacing: 8) {
                        if step.done {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(step.title)
                            .foregroundStyle(step.done ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// A small window with no close button, shown in front while DockZ quits.
@MainActor
final class ShutdownWindowController: NSWindowController {
    init(progress: ShutdownProgress) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Quitting DockZ"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: ShutdownView(progress: progress))
        window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 440, height: 160))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        // DockZ is normally a menu-bar accessory; become a regular app so the
        // window can come to the front even when no other DockZ window is open.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
