import Foundation

/// In-process test runner (`DockZ test`). Command Line Tools does not ship
/// XCTest, so DockZ's automated tests run as a plain executable subcommand
/// that asserts on the pure business logic and exits non-zero on failure.
/// Suitable for CI (`DockZ test`) and local checks.
enum TestRunner {
    private static var failures: [String] = []
    private static var checks = 0

    static func run() -> Never {
        containerConfig()
        chunkedDecoder()
        logDemux()
        dhcpLease()
        registryAuth()
        logoRepo()
        clusterTemplates()
        snapshots()
        dockerCLIResolution()

        print("")
        if failures.isEmpty {
            print("✓ ALL TESTS PASSED (\(checks) checks)")
            exit(0)
        }
        print("✗ \(failures.count) FAILED of \(checks) checks:")
        failures.forEach { print("   - \($0)") }
        exit(1)
    }

    // MARK: - Assertions

    private static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures.append(label) }
    }

    private static func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String) {
        checks += 1
        if a != b { failures.append("\(label) — got \(a), expected \(b)") }
    }

    // MARK: - Suites

    private static var fixture: [String: Any] {
        [
            "Name": "/postgres",
            "Config": [
                "Image": "postgres:17",
                "Env": ["POSTGRES_PASSWORD=secret", "PGDATA=/var/lib/postgresql/data"],
                "Cmd": ["postgres"],
                "Labels": ["com.example.role": "db"],
                "Hostname": "0ldc0ntainer",
                "Healthcheck": ["Test": ["CMD-SHELL", "pg_isready"]],
            ] as [String: Any],
            "HostConfig": [
                "Binds": ["pgdata:/var/lib/postgresql/data"],
                "PortBindings": ["5432/tcp": [["HostIp": "", "HostPort": "5432"]]],
                "RestartPolicy": ["Name": "always", "MaximumRetryCount": 0],
                "NetworkMode": "bridge",
                "Memory": 536870912,
                "CapAdd": ["SYS_NICE"],
            ] as [String: Any],
            "Mounts": [["Type": "volume", "Name": "pgdata", "Destination": "/var/lib/postgresql/data", "RW": true]],
        ]
    }

    private static func containerConfig() {
        var form = ContainerConfigBuilder.formFromInspect(fixture)
        expectEqual(form.image, "postgres:17", "form.image")
        expectEqual(form.name, "postgres", "form.name strips slash")
        expect(form.envText.contains("POSTGRES_PASSWORD=secret"), "form.env prefill")
        expectEqual(form.portsText, "5432:5432", "form.ports prefill")
        expectEqual(form.volumesText, "pgdata:/var/lib/postgresql/data", "form.volumes prefill")
        expectEqual(form.restartPolicy, "always", "form.restartPolicy")
        expect(form.network.isEmpty, "bridge → default network")
        expectEqual(form.memoryMiB, "512", "form.memory MiB")
        expectEqual(form.labelsText, "com.example.role=db", "form.labels prefill")

        form.envText = "POSTGRES_PASSWORD=newpass\nPGDATA=/var/lib/postgresql/data"
        form.portsText = "5432:5432\n15432:5432"
        form.memoryMiB = ""
        let merged = ContainerConfigBuilder.mergeForEdit(base: fixture, form: form)
        let host = merged["HostConfig"] as? [String: Any] ?? [:]
        expect((merged["Env"] as? [String])?.first == "POSTGRES_PASSWORD=newpass", "merged env updated")
        expect(merged["Hostname"] == nil, "stale hostname dropped")
        expect(merged["Config"] == nil, "flat body, no nested Config")
        expect(merged["Healthcheck"] != nil, "healthcheck preserved")
        expect((host["CapAdd"] as? [String]) == ["SYS_NICE"], "CapAdd preserved")
        expect((host["Memory"] as? Int) == 0, "memory limit cleared")
        let bindings = host["PortBindings"] as? [String: Any] ?? [:]
        expect(bindings.count == 1 && (bindings["5432/tcp"] as? [[String: Any]])?.count == 2,
               "two host ports mapped to one container port")
    }

    private static func chunkedDecoder() {
        let d = ChunkedDecoder()
        let out = d.feed(Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8))
        expectEqual(String(decoding: out, as: UTF8.self), "Wikipedia", "chunked reassembly")
        expect(d.isDone, "chunked isDone")

        let d2 = ChunkedDecoder()
        var out2 = Data()
        out2.append(d2.feed(Data("4\r\nWi".utf8)))
        out2.append(d2.feed(Data("ki\r\n0\r\n\r\n".utf8)))
        expectEqual(String(decoding: out2, as: UTF8.self), "Wiki", "chunked partial feeds")
    }

    private static func logDemux() {
        var framed = Data([1, 0, 0, 0, 0, 0, 0, 5])
        framed.append(Data("hello".utf8))
        expectEqual(DockerLogDemuxer.demux(framed), "hello", "log demux frame header")
        expectEqual(DockerLogDemuxer.demux(Data("plain".utf8)), "plain", "log demux tty passthrough")
    }

    private static func dhcpLease() {
        let leases = """
        {
          name=dockz
          ip_address=192.168.64.43
          hw_address=1,42:3e:5:3d:b5:47
        }
        """
        expectEqual(DHCPLeaseResolver.parse(leases: leases, forMAC: "42:3e:05:3d:b5:47"),
                    "192.168.64.43", "dhcp lease MAC leading-zero match")
        expect(DHCPLeaseResolver.parse(leases: leases, forMAC: "00:00:00:00:00:00") == nil,
               "dhcp lease no match → nil")
    }

    private static func registryAuth() {
        expectEqual(RegistryAuth.registryHost(forImageRef: "postgres:17"), "docker.io", "host bare→hub")
        expectEqual(RegistryAuth.registryHost(forImageRef: "registry.co:5000/app:1"), "registry.co:5000", "host private")
        let header = RegistryAuth.authHeader(username: "u", password: "p+/", serverAddress: "localhost:5000") ?? ""
        expect(!header.contains("+") && !header.contains("/"), "auth header base64url")
    }

    private static func logoRepo() {
        expectEqual(ImageLogoLoader.normalizedRepo(from: "postgres:17"), "library/postgres", "logo bare")
        expectEqual(ImageLogoLoader.normalizedRepo(from: "grafana/grafana:latest"), "grafana/grafana", "logo namespaced")
        expect(ImageLogoLoader.normalizedRepo(from: "ghcr.io/x/y") == nil, "logo private → nil")
        expect(ImageLogoLoader.normalizedRepo(from: "sha256:abcdef") == nil, "logo digest → nil")
    }

    private static func clusterTemplates() {
        expectEqual(MinimumSpec.forTemplate(.cluster(engine: .k3s, role: .master, serverName: nil)).cpus, 2, "k3s master ≥2 CPU")
        expectEqual(MinimumSpec.forTemplate(.cluster(engine: .k3s, role: .node, serverName: "m")).cpus, 1, "k3s node 1 CPU")
        expectEqual(MinimumSpec.forTemplate(.cluster(engine: .k8s, role: .node, serverName: "m")).cpus, 2, "k8s node ≥2 CPU")
        expectEqual(MachineTemplate.extractK3sToken(from: ">>> DOCKZ-K3S-TOKEN: K10abc\n"), "K10abc", "k3s token capture")
        expect(MachineTemplate.extractK8sJoinCommand(from: ">>> DOCKZ-K8S-JOIN: kubeadm join 1.2.3.4:6443 --token abc\n")?
            .hasPrefix("kubeadm join") == true, "k8s join capture")
        expect(MachineDistro.by(id: "alpine-3.22")?.supportedEngines == [.k3s], "alpine → k3s only")
        expect(MachineDistro.by(id: "debian-13")?.supportedEngines == [.k3s, .k8s], "debian → k3s+k8s")
    }

    /// The managed CLI must only be used when the host has no docker of its own,
    /// and only it may override DOCKER_CONFIG (a system docker keeps its auth).
    private static func dockerCLIResolution() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockz-cli-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DockzPaths(baseDirectory: root)

        // Nothing installed anywhere DockZ controls → no managed CLI to find.
        expect(!DockerCLIInstaller.isInstalled(paths), "managed CLI absent before install")

        // Fake an installed managed CLI.
        try? FileManager.default.createDirectory(at: paths.managedCLIDirectory,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.managedDockerCLI.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        expect(DockerCLIInstaller.isInstalled(paths), "managed CLI detected after install")

        let managed = DockerCLI.Resolved(path: paths.managedDockerCLI.path,
                                         configDirectory: paths.managedDockerConfig.path)
        let environment = DockerCLI.environment(for: managed, socketPath: "/tmp/d.sock")
        expectEqual(environment["DOCKER_HOST"], "unix:///tmp/d.sock", "DOCKER_HOST wired to socket")
        expectEqual(environment["DOCKER_CONFIG"], paths.managedDockerConfig.path,
                    "managed CLI sets DOCKER_CONFIG so compose plugin resolves")

        let system = DockerCLI.Resolved(path: "/opt/homebrew/bin/docker", configDirectory: nil)
        let systemEnvironment = DockerCLI.environment(for: system, socketPath: "/tmp/d.sock")
        expect(systemEnvironment["DOCKER_CONFIG"] == ProcessInfo.processInfo.environment["DOCKER_CONFIG"],
               "system CLI keeps the user's own DOCKER_CONFIG")

        // Pinned artefacts must carry a full SHA-256 or the install can't fail closed.
        expectEqual(DockerCLIInstaller.dockerPin.sha256.count, 64, "docker pin has a sha256")
        expectEqual(DockerCLIInstaller.composePin.sha256.count, 64, "compose pin has a sha256")
    }

    private static func snapshots() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockz-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DockzPaths(baseDirectory: root)
        // Fake disk image.
        FileManager.default.createFile(atPath: paths.diskImage.path, contents: Data("v1".utf8))

        do {
            try SnapshotStore.create(paths, name: "before", id: "s1", timestamp: "2026-01-01T00:00:00Z")
            expectEqual(SnapshotStore.list(paths).count, 1, "snapshot created + listed")
            // Mutate disk, then restore snapshot → should revert content.
            try "v2".write(to: paths.diskImage, atomically: true, encoding: .utf8)
            try SnapshotStore.restore(paths, id: "s1")
            let restored = (try? String(contentsOf: paths.diskImage, encoding: .utf8)) ?? ""
            expectEqual(restored, "v1", "snapshot restore reverts disk content")
            SnapshotStore.delete(paths, id: "s1")
            expectEqual(SnapshotStore.list(paths).count, 0, "snapshot deleted")
        } catch {
            expect(false, "snapshot round-trip threw: \(error.localizedDescription)")
        }
    }
}
