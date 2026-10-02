import SwiftUI

struct NetworksListView: View {
    @ObservedObject var store: DashboardStore
    @State private var newNetworkName = ""
    @State private var searchText = ""
    @AppStorage("dockz.list.networks.scope") private var scope = "all"

    private let filter = ListFilters.networks

    private var filtered: [NetworkSummary] {
        filter.apply(store.networks, scope: scope, query: searchText, sort: "name")
    }

    var body: some View {
        VStack(spacing: 0) {
            ListHeaderBar(
                summary: "\(store.networks.count) networks",
                prompt: "Filter networks",
                searchText: $searchText,
                scopes: filter.options(for: store.networks, query: searchText),
                scope: $scope
            )
            Divider()
            List(filtered) { network in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(network.name).font(.headline)
                            if network.isBuiltin {
                                Text("built-in")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                            }
                        }
                        Text("\(network.shortID)  ·  \(network.driver)  ·  \(network.scope)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.busyIDs.contains(network.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 8) {
                            Button {
                                store.openNetworkInspect(network)
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .help("Inspect network")
                            if !network.isBuiltin {
                                Button {
                                    store.removeNetwork(network)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("Remove network")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
            .overlay {
                if !store.networks.isEmpty && filtered.isEmpty {
                    Text("No networks match").foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                TextField("New network name (bridge driver)", text: $newNetworkName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button("Create") {
                    store.createNetwork(name: newNetworkName.trimmingCharacters(in: .whitespaces))
                    newNetworkName = ""
                }
                .disabled(newNetworkName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Prune unused") { store.pruneNetworks() }
                    .disabled(store.busyIDs.contains("prune-networks"))
            }
            .padding(10)
        }
        .navigationTitle("Networks")
        .sheet(item: $store.imageInspect) { payload in
            InspectJSONSheet(payload: payload) { store.imageInspect = nil }
        }
    }
}

/// Shared raw-JSON sheet (used by image and network inspect).
struct InspectJSONSheet: View {
    let payload: DashboardStore.ImageInspectPayload
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(payload.title).font(.headline)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(payload.json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 720, height: 480)
    }
}
