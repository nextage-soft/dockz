import SwiftUI

/// Docker Desktop-style management window with fully custom chrome: our own
/// sidebar and header (no NavigationSplitView / system toolbar — their items
/// re-layout unpredictably when the sidebar collapses).
struct DashboardRootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case containers = "Containers"
        case stacks = "Stacks"
        case images = "Images"
        case volumes = "Volumes"
        case networks = "Networks"
        case machines = "Machines"
        case registries = "Registries"
        case engine = "Engine"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .containers: return "shippingbox"
            case .stacks: return "rectangle.3.group"
            case .images: return "square.stack.3d.up"
            case .volumes: return "externaldrive"
            case .networks: return "network"
            case .machines: return "desktopcomputer"
            case .registries: return "key"
            case .engine: return "slider.horizontal.3"
            case .settings: return "gearshape"
            }
        }
    }

    @ObservedObject var store: DashboardStore
    @AppStorage("dockz.sidebar.collapsed") private var sidebarCollapsed = false
    @State private var selection: Section = .containers

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarCollapsed ? 58 : 208)
            Divider()
            VStack(spacing: 0) {
                headerBar
                Divider()
                detailView
            }
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 440)
        // Pull the content up into the (transparent) titlebar region so the
        // header row sits on the same line as the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $store.editPayload) { payload in
            RunContainerFormView(store: store, mode: .edit(payload))
        }
        .alert("Docker error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .onAppear {
            store.startAutoRefresh()
            store.loadStackFiles()
        }
        .onChange(of: store.requestedSection) { requested in
            if let requested {
                selection = requested
                store.closeDetail()
                store.requestedSection = nil
            }
        }
        .onDisappear { store.stopAutoRefresh() }
    }

    // MARK: - Header (draggable titlebar area)

    private var headerBar: some View {
        HStack(spacing: 8) {
            // The real app icon (container mark) — keeps the header in sync
            // with the bundle icon without a second asset.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 20, height: 20)
            Text("DockZ")
                .font(.headline)
            Text("v\(AppInfo.version)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .help("DockZ \(AppInfo.versionLong)")
            Text("·")
                .foregroundStyle(.tertiary)
            Text(selection.rawValue)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.bar)
    }

    // MARK: - Sidebar (collapsible to an icon rail)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Space for the window traffic lights.
            Color.clear.frame(height: 34)
            ForEach(Section.allCases) { section in
                sidebarItem(section)
            }
            Spacer()
            sidebarFooter
            collapseButton
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func sidebarItem(_ section: Section) -> some View {
        Button {
            selection = section
            store.closeDetail()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .frame(width: 18)
                if !sidebarCollapsed {
                    Text(section.rawValue)
                    Spacer()
                    if let count = count(for: section) {
                        Text(String(count))
                            .font(.caption)
                            .foregroundStyle(selection == section ? Color.accentColor : .secondary)
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, sidebarCollapsed ? 0 : 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: sidebarCollapsed ? .center : .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selection == section ? Color.accentColor.opacity(0.16) : .clear)
            )
            .foregroundStyle(selection == section ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(section.rawValue)
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        let stateLabel = store.hostActions?.vmStateLabel() ?? "?"
        let statusColor: Color = stateLabel == "Running"
            ? .green
            : (stateLabel.hasSuffix("…") ? .orange : .secondary)

        if sidebarCollapsed {
            VStack(spacing: 12) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                    .help("DockZ VM: \(stateLabel)")
                Button {
                    store.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh all")
                vmPowerButton(stateLabel: stateLabel)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("DockZ VM").font(.caption.weight(.semibold))
                    Text(stateLabel == "Running"
                         ? (store.engineReady ? "Engine running" : "Engine starting…")
                         : stateLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh all")
                vmPowerButton(stateLabel: stateLabel)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }

    @ViewBuilder
    private func vmPowerButton(stateLabel: String) -> some View {
        if stateLabel == "Running" {
            Button {
                store.hostActions?.stopVM()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Stop VM")
        } else if stateLabel == "Stopped" || stateLabel == "Failed" {
            Button {
                store.hostActions?.startVM()
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Start VM")
        }
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed.toggle() }
        } label: {
            Image(systemName: sidebarCollapsed ? "chevron.forward.2" : "chevron.backward.2")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
        .help(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .containers:
            if let selected = store.selectedContainer {
                ContainerDetailView(store: store, container: store.containers.first(where: { $0.id == selected.id }) ?? selected)
            } else {
                ContainersListView(store: store)
            }
        case .stacks: StacksListView(store: store)
        case .images: ImagesListView(store: store)
        case .volumes: VolumesListView(store: store)
        case .networks: NetworksListView(store: store)
        case .machines: MachinesListView(store: store)
        case .registries: RegistriesListView(store: store)
        case .engine: EngineSettingsView(store: store)
        case .settings: VMSettingsView(store: store)
        }
    }

    private func count(for section: Section) -> Int? {
        switch section {
        case .containers: return store.containers.count
        case .stacks: return store.stackRows.isEmpty ? nil : store.stackRows.count
        case .images: return store.images.count
        case .volumes: return store.volumes.count
        case .networks: return store.networks.count
        case .machines: return store.machineManager.machines.isEmpty ? nil : store.machineManager.machines.count
        case .registries: return store.registries.entries.isEmpty ? nil : store.registries.entries.count
        case .engine, .settings: return nil
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}
