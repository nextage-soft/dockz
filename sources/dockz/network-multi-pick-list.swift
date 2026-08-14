import SwiftUI

/// Multi-select list of docker networks for the run/edit form. Checkboxes in a
/// plain stack stop scaling past a handful of networks, so this renders a
/// bounded, scrollable, filterable pick-list instead: full-row click toggles,
/// a filter field appears once the list is long, and selections stay visible
/// even when filtered out (chips row).
struct NetworkMultiPickList: View {
    /// Network names offered for joining (already excludes primary/host/none).
    let choices: [String]
    /// name → driver, shown as a trailing badge (bridge, overlay, …).
    let drivers: [String: String]
    @Binding var selection: [String]

    @State private var filter = ""

    /// Below this many rows the filter field is just noise.
    private let filterThreshold = 6
    private let rowHeight: CGFloat = 24

    private var visible: [String] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return choices }
        return choices.filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if choices.count >= filterThreshold {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Filter \(choices.count) networks", text: $filter)
                        .textFieldStyle(.plain)
                    if !selection.isEmpty {
                        Button("Clear \(selection.count)") { selection = [] }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible, id: \.self) { name in
                        row(name)
                    }
                    if visible.isEmpty {
                        Text("No network matches “\(filter)”")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(6)
                    }
                }
            }
            .frame(height: listHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))

            // Keep every selection visible even when the filter hides its row.
            if !selection.isEmpty {
                Text("Joining: " + selection.sorted().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// Grows with content, capped so a long network list scrolls in place
    /// instead of stretching the form.
    private var listHeight: CGFloat {
        let rows = CGFloat(max(visible.count, 1))
        return min(rows * rowHeight + 8, 150)
    }

    private func row(_ name: String) -> some View {
        let isSelected = selection.contains(name)
        return Button {
            if isSelected {
                selection.removeAll { $0 == name }
            } else {
                selection.append(name)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let driver = drivers[name] {
                    Text(driver)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
    }
}
