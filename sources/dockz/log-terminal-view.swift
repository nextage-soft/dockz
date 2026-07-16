import SwiftUI

/// Terminal-styled log panel: dark background, monospace, sticks to the
/// bottom as new content arrives, one-click copy.
struct TerminalTextView: View {
    let text: String

    private static let bottomAnchor = "terminal-bottom"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "(no output)" : text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color(red: 0.85, green: 0.89, blue: 0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                .onChange(of: text) { _ in
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .padding(8)
            .help("Copy all")
        }
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
    }
}

/// Logs sheet reused from the containers list.
struct LogsSheet: View {
    let title: String
    let store: DashboardStore
    let container: ContainerSummary
    @Environment(\.dismiss) private var dismiss
    @State private var logs = "Loading…"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Logs — \(title)", systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                Button {
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload")
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            TerminalTextView(text: logs)
        }
        .frame(width: 760, height: 500)
        .onAppear(perform: load)
    }

    private func load() {
        store.fetchLogs(for: container) { logs = $0 }
    }
}
