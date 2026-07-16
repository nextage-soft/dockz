import Foundation
import Combine

/// Observable state behind the dashboard window. All published mutations on
/// the main actor; Docker API calls hop back via DispatchQueue.main.
@MainActor
final class DashboardStore: ObservableObject {
    struct HostActions {
        var restartVM: (DockzSettings) -> Void
        var currentSettings: () -> DockzSettings
        var startVM: () -> Void = {}
        var stopVM: () -> Void = {}
        var vmStateLabel: () -> String
        var storagePath: () -> String = { "~/.dockz" }
        var changeStorage: (URL) -> Void = { _ in }
        var resetStorage: () -> Void = {}
        var snapshots: () -> [DiskSnapshot] = { [] }
        var createSnapshot: (String) -> Void = { _ in }
        var restoreSnapshot: (String) -> Void = { _ in }
        var deleteSnapshot: (String) -> Void = { _ in }
    }

    @Published var containers: [ContainerSummary] = []
    @Published var images: [ImageSummary] = []
    @Published var volumes: [VolumeSummary] = []
    @Published var networks: [NetworkSummary] = []
    @Published var engineReady = false
    @Published var busyIDs: Set<String> = []
    @Published var lastError: String?

    // Detail page state
    @Published var selectedContainer: ContainerSummary?
    @Published var containerDetail: ContainerDetail?
    @Published var containerStats: ContainerStats?
    @Published var detailInspectJSON = ""
    @Published var detailLogs = ""
    @Published var detailTab = 0

    // Engine (daemon.json) state
    @Published var engineConfigText = "{}"
    @Published var engineStatus = ""

    // Base system info (Settings page, read live from the guest)
    @Published var baseSystem: [String: String] = [:]

    // Compose stacks
    @Published var stackFiles: [StackEntry] = []
    @Published var composeOutput = ""
    @Published var composeTitle = ""
    @Published var composeRunning = false
    @Published var showComposeOutput = false

    /// Set to steer the dashboard to a section (e.g. Settings… menu item).
    @Published var requestedSection: DashboardRootView.Section?

    /// Opens a `docker exec -it` shell for a running container in Terminal.app.
    func openContainerTerminal(_ container: ContainerSummary) {
        guard let docker = DockerCLI.resolve() else {
            lastError = "Docker CLI not found. Install it from Settings → Docker CLI."
            return
        }
        let socket = DockzPaths().dockerSocket.path
        var environment = ["DOCKER_HOST": "unix://\(socket)"]
        if let configDirectory = docker.configDirectory {
            environment["DOCKER_CONFIG"] = configDirectory
        }
        TerminalLauncher.launch(TerminalCommand(
            title: container.name,
            subtitle: "docker exec — \(container.image)",
            executable: docker.path,
            arguments: ["exec", "-it", container.name, "/bin/sh", "-c", "[ -x /bin/bash ] && exec bash || exec sh"],
            environment: environment
        ))
    }

    struct ImageInspectPayload: Identifiable {
        let id: String
        let title: String
        let json: String
    }
    @Published var imageInspect: ImageInspectPayload?
    @Published var editPayload: EditContainerPayload?

    var apiProvider: () -> DockerAPIClient? = { nil }
    var shellProvider: () -> DockerAPIClient.VsockConnect? = { nil }
    var hostActions: HostActions?
    let registries = RegistryStore()
    let machineManager = MachineManager()

    /// X-Registry-Auth for pulling `imageRef`, when a registry is configured.
    func pullAuthHeader(forImageRef imageRef: String) -> String? {
        guard let credentials = registries.credentials(forImageRef: imageRef) else { return nil }
        return RegistryAuth.authHeader(
            username: credentials.entry.username,
            password: credentials.password,
            serverAddress: credentials.entry.dockerServerAddress
        )
    }

    private var refreshTimer: Timer?

    // MARK: - Refresh

    func startAutoRefresh() {
        refreshAll()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshAll() {
        guard let api = apiProvider() else {
            engineReady = false
            containers = []; images = []; volumes = []
            return
        }
        engineReady = true
        if selectedContainer != nil { reloadDetail() }
        api.listAllContainers { [weak self] list in
            DispatchQueue.main.async { if self?.containers != list { self?.containers = list } }
        }
        api.listImages { [weak self] list in
            DispatchQueue.main.async { if self?.images != list { self?.images = list } }
        }
        api.listVolumes { [weak self] list in
            DispatchQueue.main.async { if self?.volumes != list { self?.volumes = list } }
        }
        api.listNetworks { [weak self] list in
            DispatchQueue.main.async { if self?.networks != list { self?.networks = list } }
        }
    }

    // MARK: - Actions

    func run(busyKey: String, _ operation: (DockerAPIClient, @escaping (String?) -> Void) -> Void) {
        guard let api = apiProvider() else { return }
        busyIDs.insert(busyKey)
        operation(api) { [weak self] errorMessage in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyIDs.remove(busyKey)
                if let errorMessage { self.lastError = errorMessage }
                self.refreshAll()
            }
        }
    }

    func containerAction(_ verb: String, _ container: ContainerSummary) {
        run(busyKey: container.id) { api, done in api.containerAction(verb, id: container.id, completion: done) }
    }

    func removeContainer(_ container: ContainerSummary) {
        run(busyKey: container.id) { api, done in api.removeContainer(id: container.id, completion: done) }
    }

    func removeImage(_ image: ImageSummary) {
        run(busyKey: image.id) { api, done in api.removeImage(id: image.id, completion: done) }
    }

    func pruneImages() {
        run(busyKey: "prune-images") { api, done in api.pruneImages(completion: done) }
    }

    func removeVolume(_ volume: VolumeSummary) {
        run(busyKey: volume.id) { api, done in api.removeVolume(name: volume.name, completion: done) }
    }

    func pruneVolumes() {
        run(busyKey: "prune-volumes") { api, done in api.pruneVolumes(completion: done) }
    }

    func fetchLogs(for container: ContainerSummary, completion: @escaping (String) -> Void) {
        guard let api = apiProvider() else {
            completion("(engine offline)")
            return
        }
        api.fetchLogs(id: container.id) { text in
            DispatchQueue.main.async { completion(text) }
        }
    }
}
