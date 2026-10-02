import SwiftUI

/// What every list page can filter by, declared once per page: scope chips
/// (each with a live count), the fields free-text search looks at, and the
/// sort orders offered. Pure value logic — the header renders it, the test
/// runner checks it.
struct ListFilter<Item> {
    struct Scope {
        let id: String
        let title: String
        let includes: (Item) -> Bool
    }

    struct Sort {
        let id: String
        let title: String
        let areInIncreasingOrder: (Item, Item) -> Bool
    }

    /// The first scope should be "All".
    var scopes: [Scope]
    /// The first sort is the default; empty keeps the source order.
    var sorts: [Sort]
    var searchKeys: (Item) -> [String]

    static var allScope: Scope { Scope(id: "all", title: "All") { _ in true } }

    func scope(_ id: String) -> Scope? { scopes.first { $0.id == id } ?? scopes.first }
    func sort(_ id: String) -> Sort? { sorts.first { $0.id == id } ?? sorts.first }

    /// Every whitespace-separated term must match some key (case- and
    /// diacritic-insensitive), so "redis prod" narrows instead of widening.
    func matches(_ item: Item, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let keys = searchKeys(item)
        return terms.allSatisfy { term in
            keys.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    func apply(_ items: [Item], scope scopeID: String, query: String, sort sortID: String) -> [Item] {
        let included = scope(scopeID)?.includes ?? { _ in true }
        let filtered = items.filter { included($0) && matches($0, query: query) }
        guard let order = sort(sortID) else { return filtered }
        return filtered.sorted(by: order.areInIncreasingOrder)
    }

    /// Chip models, counting what each scope holds under the current search.
    func options(for items: [Item], query: String) -> [ListScopeOption] {
        let searched = items.filter { matches($0, query: query) }
        return scopes.map { scope in
            ListScopeOption(id: scope.id, title: scope.title, count: searched.filter(scope.includes).count)
        }
    }

    var sortOptions: [ListSortOption] { sorts.map { ListSortOption(id: $0.id, title: $0.title) } }
}

struct ListScopeOption: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
}

struct ListSortOption: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Localized, case-insensitive name order — what people expect from Finder.
func namesAscending(_ lhs: String, _ rhs: String) -> Bool {
    lhs.localizedStandardCompare(rhs) == .orderedAscending
}

// MARK: - Header pieces

/// "All 29 · Running 8 · Stopped 21" — one tap switches scope.
struct ListScopeChips: View {
    let options: [ListScopeOption]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let selected = option.id == selection
                Button {
                    selection = option.id
                } label: {
                    HStack(spacing: 4) {
                        Text(option.title)
                        Text(String(option.count))
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .monospacedDigit()
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
                    .foregroundStyle(selected ? Color.accentColor : (option.count == 0 ? .secondary : .primary))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Sort picker behind one icon; extra toggles (e.g. "Group by stack") can
/// ride along in the same menu.
struct ListSortMenu<Extras: View>: View {
    let options: [ListSortOption]
    @Binding var selection: String
    @ViewBuilder var extras: Extras

    var body: some View {
        Menu {
            Picker("Sort by", selection: $selection) {
                ForEach(options) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.inline)
            extras
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
    }
}

extension ListSortMenu where Extras == EmptyView {
    init(options: [ListSortOption], selection: Binding<String>) {
        self.init(options: options, selection: selection) { EmptyView() }
    }
}
