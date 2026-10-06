import SwiftUI

/// Compact rounded search field used in list headers (kept out of the window
/// toolbar so it does not stretch across the titlebar).
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($focused)
                // Esc clears the search, like Finder.
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        // Gives up width first when the header row is crowded, so the scope
        // chips and buttons beside it never have to wrap.
        .frame(minWidth: 140, idealWidth: 240, maxWidth: 240)
        // ⌘F jumps here. Only one list page is on screen at a time, so the
        // shortcut always belongs to the visible list.
        .background {
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .help("Search (⌘F)")
    }
}

/// Header row above every list: scope chips (or a count summary when a list
/// has no scopes) on the left; search, sort and page actions on the right.
/// Page-level actions live here (not in the window toolbar) because
/// NavigationSplitView re-lays toolbar items out badly when the sidebar
/// collapses/expands.
struct ListHeaderBar<Trailing: View>: View {
    let summary: String
    let prompt: String
    @Binding var searchText: String
    var scopes: [ListScopeOption] = []
    var scope: Binding<String>?
    @ViewBuilder var trailing: Trailing

    init(summary: String, prompt: String, searchText: Binding<String>,
         scopes: [ListScopeOption] = [], scope: Binding<String>? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.summary = summary
        self.prompt = prompt
        _searchText = searchText
        self.scopes = scopes
        self.scope = scope
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let scope, scopes.count > 1 {
                ListScopeChips(options: scopes, selection: scope)
            } else {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SearchField(prompt: prompt, text: $searchText)
            trailing
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

extension ListHeaderBar where Trailing == EmptyView {
    init(summary: String, prompt: String, searchText: Binding<String>,
         scopes: [ListScopeOption] = [], scope: Binding<String>? = nil) {
        self.init(summary: summary, prompt: prompt, searchText: searchText,
                  scopes: scopes, scope: scope) { EmptyView() }
    }
}
