import AppKit
import SwiftUI

/// Collapsible numbered setup steps for the environment editor. Commands are
/// pre-filled from the form and copyable; each step says which machine it
/// runs on, since half of them happen on the server.
struct EnvironmentSetupGuideView: View {
    let kind: DockerEnvironment.Kind
    let address: String
    let port: Int?
    @State private var expanded: Bool

    init(kind: DockerEnvironment.Kind, address: String, port: Int?, expanded: Bool) {
        self.kind = kind
        self.address = address
        self.port = port
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                let steps = EnvironmentSetupGuide.steps(for: kind, address: address, port: port)
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    stepView(number: index + 1, step: step)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("How to set up \(kind.label)", systemImage: "list.number")
                .font(.callout.weight(.semibold))
        }
    }

    private func stepView(number: Int, step: EnvironmentSetupGuide.Step) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(step.title).font(.callout.weight(.medium))
                    if !step.commands.isEmpty {
                        Text(step.runsOn.rawValue)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(step.runsOn == .server
                                                       ? Color.orange.opacity(0.15) : Color.blue.opacity(0.12)))
                            .foregroundStyle(step.runsOn == .server ? Color.orange : Color.blue)
                    }
                }
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(step.commands, id: \.self) { command in
                    CopyableCommand(text: command)
                }
            }
        }
    }
}

/// Monospaced command block with a copy button.
struct CopyableCommand: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}
