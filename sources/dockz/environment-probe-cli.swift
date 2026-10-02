import CryptoKit
import Foundation

/// `DockZ env-probe <ssh|tls|socket> <address> [port] [cert-dir] [--relay SECONDS]`
/// — checks an environment from the terminal exactly as the dashboard would
/// reach it, and times a few calls (the first SSH call pays the handshake;
/// later ones should ride the multiplexed master). For TLS, `--relay` then
/// keeps the docker CLI relay socket up for that long so the real CLI can be
/// pointed at it.
enum EnvironmentProbeCLI {
    static func run(arguments: [String]) -> Never {
        // Line-buffered even when piped, so scripts see RELAY while it waits.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard arguments.count >= 2, let kind = DockerEnvironment.Kind(rawValue: arguments[0]) else {
            print("usage: DockZ env-probe <ssh|tls|socket> <address> [port] [cert-dir] [--relay SECONDS]")
            exit(2)
        }
        var relaySeconds: UInt32?
        var arguments = arguments
        if let flag = arguments.firstIndex(of: "--relay") {
            relaySeconds = arguments.count > flag + 1 ? UInt32(arguments[flag + 1]) : nil
            arguments.removeSubrange(flag..<min(flag + 2, arguments.count))
        }
        let port = arguments.count > 2 ? Int(arguments[2]) : nil
        let environment = DockerEnvironment(name: "probe", kind: kind, address: arguments[1], port: port)
        let endpoint: DockerEndpoint
        if kind == .tls, arguments.count > 3 {
            let directory = URL(fileURLWithPath: arguments[3])
            // An EC P-256 key.pem goes through the same signing callback the
            // Secure Enclave key uses; anything else is handed to BoringSSL.
            let clientKey: TLSDockerConnector.Target.ClientKey
            if let pem = try? String(contentsOf: directory.appendingPathComponent("key.pem"), encoding: .utf8),
               let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
                print("client key: P-256 via signing callback")
                clientKey = .signer(SigningCallbackTLSKey(publicKeyInfo: key.publicKey.derRepresentation) {
                    try key.signature(for: $0).derRepresentation
                })
            } else {
                clientKey = .pemFile
            }
            endpoint = .tls(.init(host: arguments[1], port: port ?? DockerEnvironment.defaultTLSPort,
                                  certDirectory: directory, clientKey: clientKey))
        } else {
            endpoint = environment.endpoint()
        }
        let client = DockerAPIClient(endpoint: endpoint)

        DispatchQueue.global().async {
            var failed = false
            for attempt in 1...5 {
                let started = Date()
                let done = DispatchSemaphore(value: 0)
                client.engineInfo { info, error in
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    if let info {
                        print("call \(attempt): \(ms) ms — Docker \(info.serverVersion), \(info.operatingSystem), " +
                              "\(info.osType), \(info.containersRunning)/\(info.containers) running")
                    } else {
                        print("call \(attempt): \(ms) ms — FAILED: \(error ?? "unknown")")
                        failed = true
                    }
                    done.signal()
                }
                done.wait()
                if failed { break }
            }
            if !failed {
                let done = DispatchSemaphore(value: 0)
                client.listAllContainers { list in
                    print("containers: \(list.map(\.name).sorted().joined(separator: ", "))")
                    done.signal()
                }
                done.wait()
            }
            print(failed ? "PROBE FAILED" : "PROBE OK")
            if !failed, let relaySeconds, case .tls(let target) = endpoint {
                let id = UUID()
                do {
                    try DockerCLISocketProxy.shared.serve(target, id: id)
                    print("RELAY unix://\(DockerCLISocketProxy.socketPath(for: id)) for \(relaySeconds)s")
                    sleep(relaySeconds)
                } catch {
                    print("RELAY FAILED: \(error)")
                    failed = true
                }
                DockerCLISocketProxy.shared.stop()
            }
            exit(failed ? 1 : 0)
        }
        dispatchMain()
    }
}

/// `DockZ env-guide <ssh|tls|socket> <address> [port]` — prints the same
/// setup steps the Add Environment sheet shows, for reading in a terminal.
/// With `--commands-only`, prints just one step's commands (1-based).
enum EnvironmentGuideCLI {
    static func run(arguments: [String]) -> Never {
        guard let first = arguments.first, let kind = DockerEnvironment.Kind(rawValue: first) else {
            print("usage: DockZ env-guide <ssh|tls|socket> [address] [port] [--commands-only N]")
            exit(2)
        }
        let address = arguments.count > 1 && !arguments[1].hasPrefix("--") ? arguments[1] : ""
        var relaySeconds: UInt32?
        var arguments = arguments
        if let flag = arguments.firstIndex(of: "--relay") {
            relaySeconds = arguments.count > flag + 1 ? UInt32(arguments[flag + 1]) : nil
            arguments.removeSubrange(flag..<min(flag + 2, arguments.count))
        }
        let port = arguments.count > 2 ? Int(arguments[2]) : nil
        let steps = EnvironmentSetupGuide.steps(for: kind, address: address, port: port)
        if let flag = arguments.firstIndex(of: "--commands-only"), flag + 1 < arguments.count,
           let number = Int(arguments[flag + 1]), steps.indices.contains(number - 1) {
            steps[number - 1].commands.forEach { print($0) }
            exit(0)
        }
        for (index, step) in steps.enumerated() {
            print("\(index + 1). \(step.title)" + (step.commands.isEmpty ? "" : "  [\(step.runsOn.rawValue)]"))
            print("   \(step.detail)")
            step.commands.forEach { print($0.split(separator: "\n").map { "     " + $0 }.joined(separator: "\n")) }
            print("")
        }
        exit(0)
    }
}

