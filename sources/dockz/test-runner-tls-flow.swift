import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// The whole TLS-environment path, end to end and offline: the guide's own
/// server commands make a CA and server certificate, DockZ's CSR is signed
/// with the guide's signing command, and an in-process mutual-TLS "engine"
/// answers /info — directly and through the CLI relay socket. A software
/// P-256 key stands in for the Secure Enclave (same signing-callback path,
/// no Touch ID). Needs /usr/bin/openssl and /bin/bash, both part of macOS.
extension TestRunner {
    static func tlsClientKeyFlow() {
        expectEqual(DER.length(127), [0x7F], "der: short length")
        expectEqual(DER.length(128), [0x81, 0x80], "der: long length, 1 byte")
        expectEqual(DER.length(300), [0x82, 0x01, 0x2C], "der: long length, 2 bytes")

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockz-tlsflow-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let serverDirectory = home.appendingPathComponent("docker-tls")

        // 1. Server side, exactly as the guide prints it (minus the sudo copy).
        let serverScript = EnvironmentSetupGuide.steps(for: .tls, address: "127.0.0.1", port: 2376)
            .flatMap(\.commands)
            .first { $0.contains("genrsa -out ca-key.pem") }?
            .split(separator: "\n").filter { !$0.hasPrefix("sudo") }.joined(separator: "\n") ?? ""
        expect(runShell(serverScript, home: home) == 0, "tlsflow: guide's CA + server cert script runs")

        // 2. DockZ's signing request, signed with the guide's command.
        let key = P256.Signing.PrivateKey()
        let signer = SigningCallbackTLSKey(publicKeyInfo: key.publicKey.derRepresentation) {
            try key.signature(for: $0).derRepresentation
        }
        guard let request = try? CertificateSigningRequest.pem(
            publicKeyInfo: key.publicKey.derRepresentation, commonName: "dockz-test", sign: signer.sign
        ) else {
            return expect(false, "tlsflow: CSR built")
        }
        try? request.write(to: home.appendingPathComponent("check.csr"), atomically: true, encoding: .utf8)
        expect(runShell("openssl req -in check.csr -noout -verify", home: home) == 0,
               "tlsflow: CSR is valid PKCS#10 with a correct signature")
        expect(runShell(EnvironmentSetupGuide.signingCommands(for: request), home: home) == 0,
               "tlsflow: guide's signing command signs the CSR")

        // 3. The Mac side stores only the CA and the signed certificate.
        let macDirectory = home.appendingPathComponent("mac", isDirectory: true)
        let id = UUID()
        let paths = DockzPaths(baseDirectory: macDirectory)
        let caText = (try? String(contentsOf: serverDirectory.appendingPathComponent("ca.pem"), encoding: .utf8)) ?? ""
        let certText = (try? String(contentsOf: serverDirectory.appendingPathComponent("dockz-cert.pem"), encoding: .utf8)) ?? ""
        expect(TLSDockerConnector.certificate(certText, matches: key.publicKey), "tlsflow: certificate matches the key")
        expect(!TLSDockerConnector.certificate(certText, matches: P256.Signing.PrivateKey().publicKey),
               "tlsflow: certificate doesn't match another key")
        if let expiry = TLSDockerConnector.expiry(of: certText) {
            let days = expiry.timeIntervalSinceNow / 86_400
            expect(abs(days - Double(EnvironmentSetupGuide.clientCertificateDays)) < 2, "tlsflow: certificate is short-lived")
        } else {
            expect(false, "tlsflow: certificate expiry readable")
        }
        try? EnvironmentCatalog.storeCertificate(caText, as: "ca.pem", for: id, paths: paths)
        try? EnvironmentCatalog.storeCertificate(certText, as: "cert.pem", for: id, paths: paths)
        let certDirectory = EnvironmentCatalog.certDirectory(for: id, paths: paths)

        // 4. A mutual-TLS engine that answers /info.
        guard let server = try? FakeTLSEngine.start(serverDirectory: serverDirectory) else {
            return expect(false, "tlsflow: fake engine started")
        }
        defer { try? server.close().wait() }
        let port = server.localAddress?.port ?? 0

        func info(_ endpoint: DockerEndpoint) -> (EngineInfo?, String?) {
            let done = DispatchSemaphore(value: 0)
            var result: (EngineInfo?, String?) = (nil, "timed out")
            DockerAPIClient(endpoint: endpoint).engineInfo { info, error in
                result = (info, error)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 15)
            return result
        }

        let target = TLSDockerConnector.Target(host: "127.0.0.1", port: port, certDirectory: certDirectory,
                                               clientKey: .signer(signer))
        let direct = info(.tls(target))
        expectEqual(direct.0?.serverVersion, FakeTLSEngine.version, "tlsflow: /info over mutual TLS (\(direct.1 ?? "ok"))")

        // An engine whose certificate (same CA) names a different host: the
        // server identity check must refuse it even though the CA is trusted.
        let otherHost = """
        cd ~/docker-tls
        openssl req -new -key server-key.pem -subj "/CN=other.example" -out other.csr
        printf 'subjectAltName=DNS:other.example\\nextendedKeyUsage=serverAuth\\n' > other-ext.cnf
        openssl x509 -req -days 30 -sha256 -in other.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out other-cert.pem -extfile other-ext.cnf
        """
        if runShell(otherHost, home: home) == 0,
           let impostor = try? FakeTLSEngine.start(serverDirectory: serverDirectory, certificate: "other-cert.pem") {
            var misnamed = target
            misnamed.port = impostor.localAddress?.port ?? 0
            let result = info(.tls(misnamed))
            expect(result.0 == nil && (result.1 ?? "").lowercased().contains("hostname"),
                   "tlsflow: certificate for another host refused (\(result.1 ?? "-"))")
            try? impostor.close().wait()
        } else {
            expect(false, "tlsflow: impostor engine started")
        }

        // A key the CA never signed.
        let rogue = P256.Signing.PrivateKey()
        var rogueTarget = target
        rogueTarget.clientKey = .signer(SigningCallbackTLSKey(publicKeyInfo: rogue.publicKey.derRepresentation) {
            try rogue.signature(for: $0).derRepresentation
        })
        let refused = info(.tls(rogueTarget))
        expect(refused.0 == nil, "tlsflow: unsigned key refused by the engine")
        expect(EnvironmentTroubleshooting.hint(for: .tls, error: refused.1 ?? "")?.contains("rejected this Mac") == true,
               "tlsflow: refusal names the client certificate (\(refused.1 ?? "-"))")

        // 5. The docker CLI path: plain unix socket in, TLS out.
        do {
            try DockerCLISocketProxy.shared.serve(target, id: id)
            let relayed = info(.unixSocket(path: DockerCLISocketProxy.socketPath(for: id)))
            expectEqual(relayed.0?.serverVersion, FakeTLSEngine.version, "tlsflow: /info through the CLI relay (\(relayed.1 ?? "ok"))")
            let mode = (try? FileManager.default.attributesOfItem(
                atPath: DockerCLISocketProxy.socketPath(for: id))[.posixPermissions] as? Int) ?? nil
            expectEqual(mode, 0o600, "tlsflow: relay socket private to the user")
        } catch {
            expect(false, "tlsflow: relay started — \(error)")
        }
        DockerCLISocketProxy.shared.stop()
        expect(!FileManager.default.fileExists(atPath: DockerCLISocketProxy.socketPath(for: id)), "tlsflow: relay socket removed")

        // 6. Half-close passes through both paths: the docker CLI ends exec /
        // attach input with a write-shutdown and still reads the output.
        if let echo = try? FakeTLSEngine.start(serverDirectory: serverDirectory, makeHandler: { ReplyAfterInputEnds() }) {
            var echoTarget = target
            echoTarget.port = echo.localAddress?.port ?? 0
            let done = DispatchSemaphore(value: 0)
            var direct: String?
            TLSDockerConnector.open(echoTarget) { result in
                if case .success(let stream) = result {
                    direct = exchangeWithWriteShutdown(fd: stream.fileDescriptor, payload: "ping")
                    stream.close()
                }
                done.signal()
            }
            _ = done.wait(timeout: .now() + 15)
            expectEqual(direct, "got:ping", "tlsflow: write-shutdown then read (direct)")

            let relayID = UUID()
            if (try? DockerCLISocketProxy.shared.serve(echoTarget, id: relayID)) != nil,
               let stream = try? UnixSocketConnector.open(path: DockerCLISocketProxy.socketPath(for: relayID)) {
                expectEqual(exchangeWithWriteShutdown(fd: stream.fileDescriptor, payload: "pong"), "got:pong",
                            "tlsflow: write-shutdown then read (CLI relay)")
                stream.close()
            } else {
                expect(false, "tlsflow: relay for half-close test")
            }
            DockerCLISocketProxy.shared.stop()
            try? echo.close().wait()
        } else {
            expect(false, "tlsflow: half-close engine started")
        }

        let stored = (try? FileManager.default.contentsOfDirectory(atPath: certDirectory.path)) ?? []
        expect(!stored.contains { $0.hasSuffix("key.pem") }, "tlsflow: no private key file on the Mac side")
    }

    /// Sends `payload`, shuts down writing, then reads until EOF (5 s cap).
    private static func exchangeWithWriteShutdown(fd: Int32, payload: String) -> String? {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard payload.withCString({ write(fd, $0, strlen($0)) }) == payload.utf8.count else { return nil }
        shutdown(fd, SHUT_WR)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: received, as: UTF8.self)
    }

    /// Runs `script` with bash in `home` (also $HOME, so `~/docker-tls` lands there).
    private static func runShell(_ script: String, home: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-e", "-c", script]
        process.currentDirectoryURL = home
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Requires a client certificate from the guide's CA and answers any request
/// with a minimal /info document, then closes (like `Connection: close`).
private enum FakeTLSEngine {
    static let version = "fake-29.0"

    static func start(serverDirectory: URL, certificate: String = "server-cert.pem",
                      makeHandler: @escaping () -> ChannelHandler = { InfoResponder() }) throws -> Channel {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate
                .fromPEMFile(serverDirectory.appendingPathComponent(certificate).path)
                .map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(
                file: serverDirectory.appendingPathComponent("server-key.pem").path, format: .pem))
        )
        configuration.trustRoots = .certificates(
            try NIOSSLCertificate.fromPEMFile(serverDirectory.appendingPathComponent("ca.pem").path))
        configuration.certificateVerification = .noHostnameVerification
        let context = try NIOSSLContext(configuration: configuration)
        return try ServerBootstrap(group: TLSDockerConnector.eventLoopGroup)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([NIOSSLServerHandler(context: context), makeHandler()])
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    final class InfoResponder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        private var received = ""

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            received += buffer.readString(length: buffer.readableBytes) ?? ""
            guard received.contains("\r\n\r\n") else { return }
            let body = #"{"ServerVersion":"\#(FakeTLSEngine.version)","OSType":"linux","Name":"fake"}"#
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: response))).whenComplete { _ in
                context.close(promise: nil)
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            context.close(promise: nil)
        }
    }
}

/// Like `docker exec` on the engine side: collects input until the client's
/// write-shutdown arrives, then answers and closes.
private final class ReplyAfterInputEnds: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var received = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        received += buffer.readString(length: buffer.readableBytes) ?? ""
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard case ChannelEvent.inputClosed? = event as? ChannelEvent else { return }
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: "got:\(received)"))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
