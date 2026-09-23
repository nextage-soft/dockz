import SwiftUI

/// VM time zone picker for Settings → Integration. Applies live (no VM
/// restart); "Match this Mac" follows the host zone at every boot.
struct TimeZoneSettingRow: View {
    @ObservedObject var store: DashboardStore
    @State private var selection = ""
    @State private var status = ""
    @State private var loaded = false

    /// Grouped by region prefix would be nicer, but a flat sorted menu keeps
    /// every identifier reachable with type-to-select.
    private static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("VM time zone", selection: $selection) {
                Text("Match this Mac (\(TimeZone.current.identifier))").tag("")
                Divider()
                ForEach(Self.zones, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: selection) { zone in
                guard loaded else { return }
                status = "Applying…"
                store.hostActions?.applyTimeZone(zone) { error in
                    status = error ?? (store.engineReady ? "Applied." : "Saved — applies when the VM starts.")
                }
            }
            Text(status.isEmpty
                 ? "Sets the VM's clock zone (shell, engine logs). Containers keep their own TZ — set TZ in a container's environment to change it."
                 : status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            selection = store.hostActions?.currentSettings().timeZone ?? ""
            // Setting the initial value must not trigger an apply.
            DispatchQueue.main.async { loaded = true }
        }
    }
}
