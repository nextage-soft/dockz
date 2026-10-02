import Foundation

/// The engines the dashboard can point at: the local DockZ VM (always present,
/// `selectedID == nil`) plus user-added environments. The selection is never
/// persisted — DockZ always opens on Local so a stale choice can't aim the
/// first click at a production host.
@MainActor
final class EnvironmentStore: ObservableObject {
    enum Status: Equatable {
        case unknown
        case checking
        case online(EngineInfo)
        case offline(String)
        /// TLS environment whose Secure Enclave key isn't unlocked this
        /// session — not contacted, so listing never triggers Touch ID.
        case locked
    }

    @Published private(set) var environments: [DockerEnvironment]
    @Published private(set) var selectedID: UUID?
    @Published private(set) var statuses: [UUID: Status] = [:]

    private var clients: [UUID: (environment: DockerEnvironment, client: DockerAPIClient)] = [:]
    private var lockObserver: NSObjectProtocol?

    /// Called when the selected TLS environment's session locked (screen
    /// lock, sleep); the dashboard falls back to Local.
    var onSelectedEnvironmentLocked: ((DockerEnvironment) -> Void)?

    init() {
        environments = EnvironmentCatalog.load()
        EnvironmentCatalog.removeLegacyKeyFiles(environments.filter { $0.kind == .tls })
        lockObserver = NotificationCenter.default.addObserver(
            forName: TLSClientKeyVault.didLockNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.vaultDidLock() }
        }
    }

    var selected: DockerEnvironment? { environments.first { $0.id == selectedID } }
    var isLocal: Bool { selected == nil }

    func status(of id: UUID) -> Status { statuses[id] ?? .unknown }

    /// One client per environment, rebuilt when its settings change.
    func client(for environment: DockerEnvironment) -> DockerAPIClient {
        if let cached = clients[environment.id], cached.environment == environment {
            return cached.client
        }
        let client = DockerAPIClient(endpoint: environment.endpoint())
        clients[environment.id] = (environment, client)
        return client
    }

    /// Switching away from a TLS environment locks its key again and closes
    /// its CLI relay; switching to one opens the relay (it must already be
    /// unlocked — see `unlock`).
    func select(_ id: UUID?) {
        let previous = selected
        selectedID = environments.contains { $0.id == id } ? id : nil
        if let previous, previous.kind == .tls, previous.id != selectedID {
            TLSClientKeyVault.shared.lock(previous.id)
            statuses[previous.id] = .locked
        }
        DispatchQueue.global(qos: .userInitiated).async { DockerCLISocketProxy.shared.stop() }
        if let environment = selected, environment.kind == .tls,
           case .tls(let target) = environment.endpoint() {
            DispatchQueue.global(qos: .userInitiated).async {
                try? DockerCLISocketProxy.shared.serve(target, id: environment.id)
            }
        }
    }

    /// Asks for Touch ID / the login password once for a TLS environment.
    /// Calls back on the main queue with nil on success, else the reason.
    func unlock(_ environment: DockerEnvironment, completion: @escaping (String?) -> Void) {
        guard environment.kind == .tls else { return completion(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            let reason: String?
            do {
                try TLSClientKeyVault.shared.unlock(environment.id,
                                                    reason: "connect to the Docker environment “\(environment.name)”")
                reason = nil
            } catch {
                reason = error.localizedDescription
            }
            DispatchQueue.main.async { completion(reason) }
        }
    }

    private func vaultDidLock() {
        for environment in environments where environment.kind == .tls {
            statuses[environment.id] = .locked
        }
        if let environment = selected, environment.kind == .tls {
            onSelectedEnvironmentLocked?(environment)
        }
    }

    func save(_ environment: DockerEnvironment) {
        if let index = environments.firstIndex(where: { $0.id == environment.id }) {
            environments[index] = environment
        } else {
            environments.append(environment)
        }
        clients[environment.id] = nil
        statuses[environment.id] = .unknown
        EnvironmentCatalog.save(environments)
    }

    func remove(_ id: UUID) {
        environments.removeAll { $0.id == id }
        clients[id] = nil
        statuses[id] = nil
        EnvironmentCatalog.removeData(for: id)
        EnvironmentCatalog.save(environments)
        if selectedID == id { selectedID = nil }
    }

    /// Pings via /info; the result also feeds the switcher's status dots.
    func check(_ environment: DockerEnvironment, completion: ((Status) -> Void)? = nil) {
        if let problem = environment.validationError() {
            statuses[environment.id] = .offline(problem)
            completion?(.offline(problem))
            return
        }
        if environment.kind == .tls, !TLSClientKeyVault.shared.isUnlocked(environment.id) {
            statuses[environment.id] = .locked
            completion?(.locked)
            return
        }
        statuses[environment.id] = .checking
        client(for: environment).engineInfo { [weak self] info, error in
            DispatchQueue.main.async {
                let status: Status = info.map { .online($0) } ?? .offline(error ?? "unreachable")
                self?.statuses[environment.id] = status
                completion?(status)
            }
        }
    }

    /// Refreshes every dot — run when the switcher opens, not on a timer.
    func checkAll() {
        environments.forEach { check($0) }
    }
}
