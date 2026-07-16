import Foundation
import Security

/// A configured container registry. Non-secret metadata lives in
/// ~/.dockz/registries.json; passwords/tokens live in the macOS Keychain.
struct RegistryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String        // display name, e.g. "Company GitLab"
    var server: String      // host[:port], or "docker.io" for Docker Hub
    var username: String
    var insecure = false    // plain-HTTP registry

    var isDockerHub: Bool {
        ["docker.io", "index.docker.io", "registry-1.docker.io", "hub.docker.com"].contains(server)
    }

    /// The serveraddress dockerd expects inside X-Registry-Auth.
    var dockerServerAddress: String {
        isDockerHub ? "https://index.docker.io/v1/" : server
    }
}

@MainActor
final class RegistryStore: ObservableObject {
    @Published var entries: [RegistryEntry] = []
    @Published var statuses: [UUID: String] = [:]

    private let fileURL = DockzPaths().baseDirectory.appendingPathComponent("registries.json")
    private static let keychainService = "com.nextagesoft.dockz.registries"

    init() {
        load()
    }

    // MARK: - Persistence (metadata)

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([RegistryEntry].self, from: data) else { return }
        entries = list
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL)
        }
    }

    func upsert(_ entry: RegistryEntry, password: String?) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        if let password, !password.isEmpty {
            Self.setPassword(password, server: entry.server, username: entry.username)
        }
        save()
    }

    func remove(_ entry: RegistryEntry) {
        entries.removeAll { $0.id == entry.id }
        statuses.removeValue(forKey: entry.id)
        Self.deletePassword(server: entry.server, username: entry.username)
        save()
    }

    /// Credentials to authenticate a pull of `imageRef`, if a matching
    /// registry is configured (returns nil → anonymous pull).
    func credentials(forImageRef imageRef: String) -> (entry: RegistryEntry, password: String)? {
        let host = RegistryAuth.registryHost(forImageRef: imageRef)
        let match = entries.first { entry in
            host == "docker.io" ? entry.isDockerHub : entry.server == host
        }
        guard let match,
              let password = Self.password(server: match.server, username: match.username) else { return nil }
        return (match, password)
    }

    // MARK: - Keychain

    static func password(server: String, username: String) -> String? {
        var query = baseQuery(server: server, username: username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, server: String, username: String) {
        let data = Data(password.utf8)
        var query = baseQuery(server: server, username: username)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func deletePassword(server: String, username: String) {
        SecItemDelete(baseQuery(server: server, username: username) as CFDictionary)
    }

    private static func baseQuery(server: String, username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(server)|\(username)",
        ]
    }
}
