import SwiftUI

struct ImagesListView: View {
    @ObservedObject var store: DashboardStore
    @State private var pullReference = ""
    @State private var searchText = ""
    @State private var pendingRemoval: ImageSummary?
    @AppStorage("dockz.list.images.scope") private var scope = "all"
    @AppStorage("dockz.list.images.sort") private var sort = "name"

    private var filter: ListFilter<ImageSummary> {
        ListFilters.images(usedImageIDs: Set(store.containers.map(\.imageID)))
    }

    private var filtered: [ImageSummary] {
        filter.apply(store.images, scope: scope, query: searchText, sort: sort)
    }

    var body: some View {
        VStack(spacing: 0) {
            ListHeaderBar(
                summary: "\(store.images.count) \(store.images.count == 1 ? "image" : "images")",
                prompt: "Filter images",
                searchText: $searchText,
                scopes: filter.options(for: store.images, query: searchText),
                scope: $scope
            ) {
                ListSortMenu(options: filter.sortOptions, selection: $sort)
                Button("Prune dangling") { store.pruneImages() }
                    .disabled(store.busyIDs.contains("prune-images"))
            }
            Divider()
            imagesList
        }
    }

    private var imagesList: some View {
        List(filtered) { image in
            HStack(spacing: 12) {
                ContainerAvatar(name: image.repoTag, running: true, imageRef: image.repoTag)
                VStack(alignment: .leading, spacing: 3) {
                    Text(image.repoTag).font(.system(.body, weight: .semibold))
                    Text("\(image.shortID)  ·  \(image.sizeLabel)  ·  \(image.createdLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.busyIDs.contains(image.id) {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 10) {
                        Button {
                            store.openImageDetail(image)
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .help("Inspect image")
                        Button {
                            pendingRemoval = image
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove image…")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
        .confirmationDialog(
            "Remove image \"\(pendingRemoval?.repoTag ?? "")\"\(store.targetSuffix)?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let image = pendingRemoval { store.removeImage(image) }
                pendingRemoval = nil
            }
        }
        .sheet(item: $store.imageInspect) { payload in
            InspectJSONSheet(payload: payload) { store.imageInspect = nil }
        }
        .overlay {
            if store.images.isEmpty {
                Text("No images").foregroundStyle(.secondary)
            } else if filtered.isEmpty {
                Text("No images match").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Images")
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("Pull image (e.g. redis:7-alpine)", text: $pullReference)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { pull() }
                if store.busyIDs.contains("pull-image") {
                    ProgressView().controlSize(.small)
                    Text("Pulling…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Pull") { pull() }
                        .disabled(pullReference.trimmingCharacters(in: .whitespaces).isEmpty || !store.engineReady)
                }
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
    }

    private func pull() {
        store.pullImage(reference: pullReference)
        pullReference = ""
    }
}

struct VolumesListView: View {
    @ObservedObject var store: DashboardStore
    @State private var pendingRemoval: VolumeSummary?
    @State private var searchText = ""
    @AppStorage("dockz.list.volumes.scope") private var scope = "all"
    @AppStorage("dockz.list.volumes.sort") private var sort = "name"

    private var filter: ListFilter<VolumeSummary> {
        ListFilters.volumes(usedVolumeNames: Set(store.containers.flatMap(\.volumeNames)))
    }

    private var filtered: [VolumeSummary] {
        filter.apply(store.volumes, scope: scope, query: searchText, sort: sort)
    }

    var body: some View {
        VStack(spacing: 0) {
            ListHeaderBar(
                summary: "\(store.volumes.count) \(store.volumes.count == 1 ? "volume" : "volumes")",
                prompt: "Filter volumes",
                searchText: $searchText,
                scopes: filter.options(for: store.volumes, query: searchText),
                scope: $scope
            ) {
                Button("Prune unused") { store.pruneVolumes() }
                    .disabled(store.busyIDs.contains("prune-volumes"))
            }
            Divider()
            volumesList
        }
    }

    private var volumesList: some View {
        List(filtered) { volume in
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.title3)
                    .foregroundStyle(.orange.opacity(0.75))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(volume.name).font(.system(.body, weight: .semibold))
                    Text("\(volume.driver)  ·  \(volume.mountpoint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if store.busyIDs.contains(volume.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        pendingRemoval = volume
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove volume…")
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
        .confirmationDialog(
            "Remove volume \"\(pendingRemoval?.name ?? "")\"\(store.targetSuffix)?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove — data is deleted", role: .destructive) {
                if let volume = pendingRemoval { store.removeVolume(volume) }
                pendingRemoval = nil
            }
        }
        .overlay {
            if store.volumes.isEmpty {
                Text("No volumes").foregroundStyle(.secondary)
            } else if filtered.isEmpty {
                Text("No volumes match").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Volumes")
    }
}
