import SwiftUI

/// "Clean Up" panel: pick what to prune (old images, build cache, …), run it,
/// and see how much came back. Pruning frees space inside the VM; the store
/// follows up with a disk reclaim so the bytes return to the Mac too.
struct CleanupSheetView: View {
    @ObservedObject var store: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var options = DashboardStore.CleanupOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "paintbrush")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Clean Up").font(.headline)
                    Text("Removes unused docker data, then returns the space to your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Unused images (not used by any container)", isOn: $options.unusedImages)
                    Toggle("Build cache", isOn: $options.buildCache)
                    Toggle("Stopped containers", isOn: $options.stoppedContainers)
                    Toggle("Unused networks", isOn: $options.unusedNetworks)
                    Toggle(isOn: $options.unusedVolumes) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Unused volumes")
                            Text("Deletes data in volumes no container uses — cannot be undone.")
                                .font(.caption2).foregroundStyle(.red)
                        }
                    }
                }
                .padding(6)
            }

            if !store.cleanupResult.isEmpty {
                Text(store.cleanupResult)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !store.reclaimResult.isEmpty && !store.cleanupBusy {
                Text(store.reclaimResult)
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if store.cleanupBusy || store.reclaimBusy {
                    ProgressView().controlSize(.small)
                    Text(store.cleanupBusy ? "Cleaning…" : "Reclaiming…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Clean Up") { store.cleanUp(options) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.cleanupBusy || store.reclaimBusy || !store.engineReady || nothingSelected)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private var nothingSelected: Bool {
        !(options.unusedImages || options.buildCache || options.stoppedContainers
          || options.unusedNetworks || options.unusedVolumes)
    }
}
