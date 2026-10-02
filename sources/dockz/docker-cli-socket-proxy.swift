import Foundation
import NIOCore
import NIOPosix

/// Lets the docker CLI (compose, exec shells) reach a TLS environment without
/// ever touching its key: DockZ listens on a private unix socket and relays
/// each CLI connection over its own Secure Enclave–backed TLS connection.
/// The CLI just gets `DOCKER_HOST=unix://…`.
///
/// The socket lives in the per-user temporary folder (already 0700) inside a
/// 0700 subfolder, exists only while the environment is selected and DockZ
/// runs, and stops working the moment the environment locks.
final class DockerCLISocketProxy {
    static let shared = DockerCLISocketProxy()

    private let lock = NSLock()
    private var server: Channel?
    private var serving: UUID?

    /// Short on purpose: unix socket paths are capped at 104 bytes and
    /// $TMPDIR alone is ~50.
    static func socketPath(for id: UUID) -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dockz-cli", isDirectory: true)
        return directory.appendingPathComponent("\(id.uuidString.prefix(8).lowercased()).sock").path
    }

    /// Serves `target` (replacing whatever was served). Blocking; call off main.
    func serve(_ target: TLSDockerConnector.Target, id: UUID) throws {
        stop()
        let path = Self.socketPath(for: id)
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)

        let channel = try ServerBootstrap(group: TLSDockerConnector.eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            // Hold the CLI's bytes until the TLS side is ready to take them.
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { cliChannel in
                // Same loop for both sides: the glue never crosses threads.
                TLSDockerConnector.connect(target, on: cliChannel.eventLoop).flatMap { tlsChannel in
                    ChannelGlue.join(cliChannel, tlsChannel).flatMap {
                        cliChannel.setOption(ChannelOptions.autoRead, value: true)
                    }
                }
            }
            .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true)
            .wait()
        chmod(path, 0o600)
        lock.lock()
        server = channel
        serving = id
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let channel = server
        let id = serving
        server = nil
        serving = nil
        lock.unlock()
        try? channel?.close().wait()
        if let id { unlink(Self.socketPath(for: id)) }
    }
}

/// Relays bytes between two channels until both are done. Each side reads
/// only while its partner can take more (backpressure). Half-closes pass
/// through: the docker CLI ends `exec`/`attach` input with a write-shutdown
/// and keeps reading output, so an EOF on one side only ends writing on the
/// other (after what it already received is written). Both channels need
/// `allowRemoteHalfClosure`.
enum ChannelGlue {
    static func join(_ first: Channel, _ second: Channel) -> EventLoopFuture<Void> {
        let (a, b) = GlueHandler.matchedPair()
        return first.pipeline.addHandler(a).and(second.pipeline.addHandler(b)).map { _ in }
    }
}

/// Both channels must share one event loop (callers guarantee it).
private final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    private var lastWrite: EventLoopFuture<Void>?

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        // The partner may have deferred a read while waiting for this side.
        partner?.partnerBecameWritable()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    // MARK: Partner-facing

    private func run(_ body: (ChannelHandlerContext) -> Void) {
        guard let context else { return }
        context.eventLoop.preconditionInEventLoop()
        body(context)
    }

    fileprivate func partnerWrite(_ data: NIOAny) {
        run { [weak self] context in
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.write(data, promise: promise)
            self?.lastWrite = promise.futureResult
        }
    }

    fileprivate func partnerFlush() {
        run { $0.flush() }
    }

    /// Partner's input ended: stop writing here once everything it sent us
    /// has been written (a write-shutdown, or close_notify on TLS).
    fileprivate func partnerInputEnded() {
        run { [weak self] context in
            context.flush()
            let shutdown = { context.close(mode: .output, promise: nil) }
            if let pending = self?.lastWrite {
                pending.whenComplete { _ in shutdown() }
            } else {
                shutdown()
            }
        }
    }

    /// Partner went away: close once everything it sent us has been written.
    fileprivate func partnerClosed() {
        run { [weak self] context in
            context.flush()
            if let pending = self?.lastWrite {
                pending.whenComplete { _ in context.close(promise: nil) }
            } else {
                context.close(promise: nil)
            }
        }
    }

    fileprivate func partnerBecameWritable() {
        run { [weak self] context in
            guard let self, self.pendingRead else { return }
            self.pendingRead = false
            context.read()
        }
    }

    fileprivate var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }

    // MARK: Channel events

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerClosed()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed? = event as? ChannelEvent {
            partner?.partnerInputEnded()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
