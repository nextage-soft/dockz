import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// Reaches a remote engine over mutual TLS (dockerd `--tlsverify`, port 2376)
/// with swift-nio-ssl. The environment folder holds the server's CA
/// (`ca.pem`) and this Mac's client certificate (`cert.pem`); the client key
/// stays in the Secure Enclave and signs each handshake through
/// `SigningCallbackTLSKey`, so no private key file exists anywhere.
enum TLSDockerConnector {
    struct Target: Equatable {
        enum ClientKey: Equatable {
            /// The environment's Secure Enclave key — what saved environments use.
            case secureEnclave(environmentID: UUID)
            /// Any P-256 signer (the test suite drives the full TLS path with
            /// a software key through this, without Touch ID).
            case signer(SigningCallbackTLSKey)
            /// `key.pem` beside the certificates. Only `DockZ env-probe` uses
            /// this, against throwaway test engines.
            case pemFile
        }

        var host: String
        var port: Int
        var certDirectory: URL
        var clientKey: ClientKey
    }

    static let certificateFileNames = ["ca.pem", "cert.pem"]

    static func missingCertificates(in directory: URL) -> [String] {
        certificateFileNames.filter { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// Two loops are plenty: every call is short and the work is I/O.
    static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    static let handshakeTimeout: TimeAmount = .seconds(10)

    /// A TLS channel whose handshake already completed, so certificate and
    /// authentication errors surface here instead of mid-request.
    static func connect(_ target: Target, on eventLoop: EventLoop? = nil) -> EventLoopFuture<Channel> {
        let loop = eventLoop ?? eventLoopGroup.next()
        let context: NIOSSLContext
        do {
            context = try makeContext(target)
        } catch {
            return loop.makeFailedFuture(error)
        }
        let label = "\(target.host):\(target.port)"
        let handshake = loop.makePromise(of: Void.self)
        // An IP must not go in SNI; NIO then checks the certificate's IP SANs
        // against the connected address instead of a name.
        let serverName = isIPAddress(target.host) ? nil : target.host

        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(handshakeTimeout)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                do {
                    let tls = try NIOSSLClientHandler(context: context, serverHostname: serverName)
                    return channel.pipeline.addHandlers([tls, HandshakeWatcher(promise: handshake)])
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let timeout = loop.scheduleTask(in: handshakeTimeout) {
            handshake.fail(DockzError.socketSetupFailed("\(label) — TLS handshake timed out"))
        }
        return bootstrap.connect(host: target.host, port: target.port)
            .flatMapError { error in
                handshake.fail(error)
                return loop.makeFailedFuture(error)
            }
            .flatMap { channel in
                handshake.futureResult
                    .map { channel }
                    .flatMapError { error in
                        channel.close(promise: nil)
                        return loop.makeFailedFuture(error)
                    }
            }
            .always { _ in timeout.cancel() }
            .flatMapErrorThrowing { error in
                if error is DockzError || error is TLSClientKeyVault.VaultError { throw error }
                throw DockzError.socketSetupFailed("\(label) — \(String(describing: error))")
            }
    }

    /// Opens the TLS connection and bridges it onto a socketpair, so the HTTP
    /// layer reads a plain file descriptor like every other transport.
    static func open(_ target: Target, completion callerCompletion: @escaping (Result<DockerByteStream, Error>) -> Void) {
        // Never call back on the event loop: callers do blocking reads on the
        // stream, and that loop is the one relaying its bytes.
        let completion: (Result<DockerByteStream, Error>) -> Void = { result in
            DispatchQueue.global(qos: .userInitiated).async { callerCompletion(result) }
        }
        connect(target).whenComplete { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let tlsChannel):
                do {
                    let pair = try SocketPair.make()
                    let errors = TLSErrorRecorder()
                    ClientBootstrap(group: tlsChannel.eventLoop)
                        .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        .channelInitializer { appChannel in
                            tlsChannel.pipeline.addHandler(errors).flatMap {
                                ChannelGlue.join(appChannel, tlsChannel)
                            }
                        }
                        .withConnectedSocket(pair.remote)
                        .whenComplete { joined in
                            switch joined {
                            case .success:
                                completion(.success(FileDescriptorStream(
                                    fileDescriptor: pair.local,
                                    onClose: { tlsChannel.close(promise: nil) },
                                    diagnostics: { errors.message }
                                )))
                            case .failure(let error):
                                Darwin.close(pair.local)
                                tlsChannel.close(promise: nil)
                                completion(.failure(error))
                            }
                        }
                } catch {
                    tlsChannel.close(promise: nil)
                    completion(.failure(error))
                }
            }
        }
    }

    /// Trust only the environment's CA (never the system roots) and require
    /// the server certificate to match the host — what `docker --tlsverify` does.
    static func makeContext(_ target: Target) throws -> NIOSSLContext {
        let missing = missingCertificates(in: target.certDirectory)
        guard missing.isEmpty else {
            throw DockzError.socketSetupFailed("missing \(missing.joined(separator: ", "))")
        }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.certificateVerification = .fullVerification
        configuration.trustRoots = .certificates(
            try NIOSSLCertificate.fromPEMFile(target.certDirectory.appendingPathComponent("ca.pem").path)
        )
        configuration.certificateChain = try NIOSSLCertificate
            .fromPEMFile(target.certDirectory.appendingPathComponent("cert.pem").path)
            .map { .certificate($0) }
        switch target.clientKey {
        case .secureEnclave(let id):
            let keyURL = target.certDirectory.appendingPathComponent(TLSClientKeyVault.keyFileName)
            let key = try TLSClientKeyVault.shared.signingKey(for: id, at: keyURL)
            configuration.privateKey = .privateKey(NIOSSLPrivateKey(customPrivateKey: SigningCallbackTLSKey(key)))
        case .signer(let signer):
            configuration.privateKey = .privateKey(NIOSSLPrivateKey(customPrivateKey: signer))
        case .pemFile:
            configuration.privateKey = .privateKey(try NIOSSLPrivateKey(
                file: target.certDirectory.appendingPathComponent("key.pem").path, format: .pem))
        }
        return try NIOSSLContext(configuration: configuration)
    }

    static func isIPAddress(_ host: String) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16)
        return inet_pton(AF_INET, host, &buffer) == 1 || inet_pton(AF_INET6, host, &buffer) == 1
    }

    /// Does `certificatePEM` certify `publicKey`? Catches a certificate issued
    /// for another key (or an older key of this environment) before connecting.
    static func certificate(_ certificatePEM: String, matches publicKey: P256.Signing.PublicKey) -> Bool {
        guard let certificate = try? NIOSSLCertificate.fromPEMBytes(Array(certificatePEM.utf8)).first,
              let spki = try? certificate.extractPublicKey().toSPKIBytes() else { return false }
        return spki == Array(publicKey.derRepresentation)
    }

    /// Expiry of the first certificate in `certificatePEM`.
    static func expiry(of certificatePEM: String) -> Date? {
        guard let certificate = try? NIOSSLCertificate.fromPEMBytes(Array(certificatePEM.utf8)).first else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(certificate.notValidAfter))
    }
}

/// Lets BoringSSL use a key it can't read: it hands over the handshake bytes
/// and `sign` returns an ECDSA P-256 / SHA-256 signature (DER). For a Secure
/// Enclave key the chip does the signing; the key itself is never readable.
struct SigningCallbackTLSKey: NIOSSLCustomPrivateKey, Hashable, @unchecked Sendable {
    /// SubjectPublicKeyInfo DER — identifies the key (and gives Hashable).
    let publicKeyInfo: Data
    let sign: (Data) throws -> Data

    init(publicKeyInfo: Data, sign: @escaping (Data) throws -> Data) {
        self.publicKeyInfo = publicKeyInfo
        self.sign = sign
    }

    init(_ key: SecureEnclave.P256.Signing.PrivateKey) {
        self.init(publicKeyInfo: key.publicKey.derRepresentation) { try key.signature(for: $0).derRepresentation }
    }

    var signatureAlgorithms: [SignatureAlgorithm] { [.ecdsaSecp256R1Sha256] }

    func sign(channel: Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        guard algorithm == .ecdsaSecp256R1Sha256 else {
            return channel.eventLoop.makeFailedFuture(
                DockzError.socketSetupFailed("server asked for an unsupported signature algorithm"))
        }
        let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
        let message = Data(data.readableBytesView)
        // A Secure Enclave signature takes a few milliseconds — keep it off the loop.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                promise.succeed(ByteBuffer(bytes: try sign(message)))
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    func decrypt(channel: Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        channel.eventLoop.makeFailedFuture(DockzError.socketSetupFailed("EC keys don't decrypt"))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.publicKeyInfo == rhs.publicKeyInfo }
    func hash(into hasher: inout Hasher) { hasher.combine(publicKeyInfo) }
}

/// Keeps the first TLS error after the handshake. Under TLS 1.3 the server
/// judges the client certificate only after the client considers the
/// handshake done, so a rejection arrives as an alert on the open connection;
/// without this the caller would only see "connection closed".
private final class TLSErrorRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny

    private let lock = NSLock()
    private var first: String?

    var message: String? {
        lock.lock(); defer { lock.unlock() }
        return first
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // A peer closing without close_notify is routine for HTTP; not a reason.
        if case NIOSSLError.uncleanShutdown? = error as? NIOSSLError {
            return context.fireErrorCaught(error)
        }
        lock.lock()
        if first == nil { first = String(describing: error) }
        lock.unlock()
        context.fireErrorCaught(error)
    }
}

/// Completes `promise` when the handshake finishes or fails, then stays inert.
private final class HandshakeWatcher: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let promise: EventLoopPromise<Void>
    private var finished = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted? = event as? TLSUserEvent {
            finish(nil)
            context.pipeline.removeHandler(self, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(DockzError.socketSetupFailed("connection closed during the TLS handshake"))
        context.fireChannelInactive()
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        if let error { promise.fail(error) } else { promise.succeed(()) }
    }
}
