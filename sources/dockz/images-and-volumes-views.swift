import SwiftUI

struct ImagesListView: View {
    @ObservedObject var store: DashboardStore
    @State private var pullReference = ""
    @State private var searchText = ""
    @State private var pendingRemoval: ImageSummary?

    private var filtered: [ImageSummary] {
        guard !searchText.isEmpty else { return store.images }
        return store.images.filter { $0.repoTag.lowercased().contains(searchText.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ListHeaderBar(
                summary: "\(store.images.count) \(store.images.count == 1 ? "image" : "images")",
                prompt: "Filter images",
                searchText: $searchText
            ) {
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
            "Remove image \"\(pendingRemoval?.repoTag ?? "")\"?",
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.volumes.count) \(store.volumes.count == 1 ? "volume" : "volumes")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Prune unused") { store.pruneVolumes() }
                    .disabled(store.busyIDs.contains("prune-volumes"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            volumesList
        }
    }

    private var volumesList: some View {
        List(store.volumes) { volume in
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
            "Remove volume \"\(pendingRemoval?.name ?? "")\"?",
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
            }
        }
        .navigationTitle("Volumes")
    }
}
