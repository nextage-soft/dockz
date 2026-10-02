import AppKit
import CryptoKit
import Foundation
import LocalAuthentication

/// Client keys for TLS environments. Each key is generated inside this Mac's
/// Secure Enclave and never exists anywhere else: what DockZ stores
/// (`client-key.se`) is an opaque handle only this chip can use, so copying
/// DockZ's files, backups or the disk yields nothing usable. Every signature
/// also needs the owner's presence (Touch ID or the login password), enforced
/// by the chip — not by DockZ — so code that hijacks the app can't use the
/// key silently.
///
/// To avoid a prompt per API call (every call is a fresh TLS handshake), one
/// authentication unlocks an environment until the screen locks, the Mac
/// sleeps, or the user switches away. Nothing here ever prompts implicitly:
/// callers unlock explicitly from a user action.
final class TLSClientKeyVault {
    static let shared = TLSClientKeyVault()
    static let keyFileName = "client-key.se"

    enum VaultError: LocalizedError {
        case locked
        case noKey
        case secureEnclaveUnavailable
        case cancelled(String)

        var errorDescription: String? {
            switch self {
            case .locked: return "Locked — select the environment again to unlock it with Touch ID"
            case .noKey: return "No client key yet — create one under Environments → Edit"
            case .secureEnclaveUnavailable: return "This Mac has no Secure Enclave"
            case .cancelled(let reason): return "Not unlocked: \(reason)"
            }
        }
    }

    /// Posted (on the main queue) after every unlocked session was dropped.
    static let didLockNotification = Notification.Name("TLSClientKeyVault.didLock")

    private let lock = NSLock()
    private var sessions: [UUID: LAContext] = [:]
    /// Held for a whole unlock so concurrent callers share one prompt.
    private let unlockSerial = NSLock()
    private var observers: [NSObjectProtocol] = []

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.lockAll() })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.lockAll() })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.lockAll() })
    }

    static func keyURL(for id: UUID, paths: DockzPaths = DockzPaths()) -> URL {
        EnvironmentCatalog.certDirectory(for: id, paths: paths).appendingPathComponent(keyFileName)
    }

    static func hasKey(for id: UUID, paths: DockzPaths = DockzPaths()) -> Bool {
        FileManager.default.fileExists(atPath: keyURL(for: id, paths: paths).path)
    }

    // MARK: - Key lifecycle

    /// Generates a new key for `id`, replacing any previous one (whose
    /// certificate then stops matching). Generating doesn't prompt; using does.
    @discardableResult
    func createKey(for id: UUID, paths: DockzPaths = DockzPaths()) throws -> P256.Signing.PublicKey {
        guard SecureEnclave.isAvailable else { throw VaultError.secureEnclaveUnavailable }
        var error: Unmanaged<CFError>?
        // userPresence: Touch ID, or the login password when Touch ID is
        // unavailable (clamshell, no enrolled finger). ThisDeviceOnly: never
        // migrates to another Mac.
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let directory = EnvironmentCatalog.certDirectory(for: id, paths: paths)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = Self.keyURL(for: id, paths: paths)
        try key.dataRepresentation.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lock(id)
        return key.publicKey
    }

    /// The public half — readable without authentication.
    func publicKey(for id: UUID, paths: DockzPaths = DockzPaths()) throws -> P256.Signing.PublicKey {
        try loadKey(at: Self.keyURL(for: id, paths: paths), context: nil).publicKey
    }

    // MARK: - Sessions

    func isUnlocked(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[id] != nil
    }

    /// Blocking — call off the main thread. Shows the system Touch ID /
    /// password sheet unless `id` is already unlocked.
    func unlock(_ id: UUID, reason: String) throws {
        unlockSerial.lock()
        defer { unlockSerial.unlock() }
        if isUnlocked(id) { return }
        let context = LAContext()
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            if !success { failure = error ?? VaultError.cancelled("authentication failed") }
            done.signal()
        }
        done.wait()
        if let failure {
            throw VaultError.cancelled(failure.localizedDescription)
        }
        lock.lock()
        sessions[id] = context
        lock.unlock()
    }

    func lock(_ id: UUID) {
        lock.lock()
        let context = sessions.removeValue(forKey: id)
        lock.unlock()
        context?.invalidate()
    }

    func lockAll() {
        lock.lock()
        let all = sessions
        sessions.removeAll()
        lock.unlock()
        guard !all.isEmpty else { return }
        all.values.forEach { $0.invalidate() }
        NotificationCenter.default.post(name: Self.didLockNotification, object: self)
    }

    /// The key bound to the unlocked session, so signing doesn't prompt.
    /// Throws `.locked` rather than prompting from a background connection.
    func signingKey(for id: UUID, at keyURL: URL) throws -> SecureEnclave.P256.Signing.PrivateKey {
        lock.lock()
        let context = sessions[id]
        lock.unlock()
        guard let context else { throw VaultError.locked }
        return try loadKey(at: keyURL, context: context)
    }

    private func loadKey(at url: URL, context: LAContext?) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard let blob = try? Data(contentsOf: url) else { throw VaultError.noKey }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
    }
}

/// PKCS#10 certificate signing request for a P-256 key, DER-encoded by hand
/// (macOS has no CSR API). The server admin signs it with their CA; only the
/// public key ever leaves this Mac.
enum CertificateSigningRequest {
    /// - Parameters:
    ///   - publicKeyInfo: SubjectPublicKeyInfo DER (`P256…PublicKey.derRepresentation`).
    ///   - sign: ECDSA-SHA256 over the given bytes, DER signature out.
    static func pem(publicKeyInfo: Data, commonName: String, sign: (Data) throws -> Data) throws -> String {
        let commonNameOID: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
        let name = DER.sequence(DER.set(DER.sequence(commonNameOID + DER.tlv(0x0C, Array(commonName.utf8)))))
        let info = DER.sequence(
            [0x02, 0x01, 0x00]            // version 0
            + name
            + Array(publicKeyInfo)
            + [0xA0, 0x00]                // attributes: none
        )
        let ecdsaWithSHA256: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
        let signature = try sign(Data(info))
        let request = DER.sequence(info + DER.sequence(ecdsaWithSHA256) + DER.tlv(0x03, [0x00] + Array(signature)))
        let body = Data(request).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE REQUEST-----\n\(body)\n-----END CERTIFICATE REQUEST-----\n"
    }

    /// Readable, unique-enough subject: "dockz-<this Mac>".
    static var defaultCommonName: String {
        let host = (Host.current().localizedName ?? "mac")
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "dockz-" + String(host.prefix(40))
    }
}

/// Minimal DER encoding (definite lengths) for the CSR above.
enum DER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func sequence(_ content: [UInt8]) -> [UInt8] { tlv(0x30, content) }
    static func set(_ content: [UInt8]) -> [UInt8] { tlv(0x31, content) }

    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
