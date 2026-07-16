import SwiftUI

/// Compact rounded search field used in list headers (kept out of the window
/// toolbar so it does not stretch across the titlebar).
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.callout)
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
        .frame(width: 240)
    }
}

/// Header row above lists: count summary left, search + page actions right.
/// Page-level actions live here (not in the window toolbar) because
/// NavigationSplitView re-lays toolbar items out badly when the sidebar
/// collapses/expands.
struct ListHeaderBar<Trailing: View>: View {
    let summary: String
    let prompt: String
    @Binding var searchText: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            SearchField(prompt: prompt, text: $searchText)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

extension ListHeaderBar where Trailing == EmptyView {
    init(summary: String, prompt: String, searchText: Binding<String>) {
        self.init(summary: summary, prompt: prompt, searchText: searchText) { EmptyView() }
    }
}
