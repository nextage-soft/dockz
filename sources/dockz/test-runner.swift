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
        buildStepMarkers()
        containerNetworks()
        shellIntegration()
        diskUsage()
        cleanupPrune()
        monitorParsing()
        advancedSettings()
        portBindAddresses()
        guestTimeZone()

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
            "NetworkSettings": ["Networks": ["bridge": [:], "backend": [:], "metrics": [:]]] as [String: Any],
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
        expectEqual(form.extraNetworks, ["backend", "metrics"], "extra networks prefilled, primary excluded")
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

    /// Forwarded ports listen where docker published them: wildcard by
    /// default (reachable from the LAN), loopback only when asked for.
    private static func portBindAddresses() {
        let containers: [[String: Any]] = [
            ["Ports": [
                ["IP": "0.0.0.0", "PublicPort": 8080, "PrivatePort": 80, "Type": "tcp"],
                ["IP": "::", "PublicPort": 8080, "PrivatePort": 80, "Type": "tcp"],
                ["IP": "127.0.0.1", "PublicPort": 5432, "PrivatePort": 5432, "Type": "tcp"],
                ["IP": "0.0.0.0", "PublicPort": 5353, "PrivatePort": 53, "Type": "udp"],
                ["PrivatePort": 9000, "Type": "tcp"],
            ]],
        ]
        let bindings = DockerAPIClient.publishedPortBindings(containers)
        expectEqual(bindings.tcp[8080], "0.0.0.0", "port: -p 8080:80 listens on all interfaces")
        expectEqual(bindings.tcp[5432], "127.0.0.1", "port: -p 127.0.0.1:… stays loopback")
        expectEqual(bindings.udp[5353], "0.0.0.0", "port: udp wildcard")
        expectEqual(bindings.tcp.count, 2, "port: unpublished (no PublicPort) ignored")

        // Loopback listed first must not shadow a later wildcard entry.
        let mixed = DockerAPIClient.publishedPortBindings([["Ports": [
            ["IP": "127.0.0.1", "PublicPort": 3000, "Type": "tcp"],
            ["IP": "0.0.0.0", "PublicPort": 3000, "Type": "tcp"],
        ]]])
        expectEqual(mixed.tcp[3000], "0.0.0.0", "port: wildcard wins over loopback")
        expectEqual(DockerAPIClient.listenAddress(forDockerHostIP: "::1"), "127.0.0.1", "port: ipv6 loopback")
    }

    /// VM time zone: host TZif is reused, unknown ids are rejected before any
    /// path or script is built from them.
    private static func guestTimeZone() {
        expectEqual(GuestTimeZone.effectiveIdentifier(setting: ""), TimeZone.current.identifier,
                    "tz: empty follows the Mac")
        expectEqual(GuestTimeZone.effectiveIdentifier(setting: "Asia/Tokyo"), "Asia/Tokyo", "tz: explicit zone")
        expect(GuestTimeZone.zoneData(for: "Asia/Ho_Chi_Minh") != nil, "tz: host zoneinfo readable as TZif")
        expect(GuestTimeZone.zoneData(for: "../../etc/passwd") == nil, "tz: path traversal rejected")
        expect(GuestTimeZone.zoneData(for: "Not/AZone") == nil, "tz: unknown zone rejected")
        let script = GuestTimeZone.installScript(identifier: "UTC", zoneData: Data("TZif".utf8))
        expect(script.contains("> /etc/localtime") && script.contains("DOCKZ-TZ"), "tz: script writes localtime")
    }

    /// Advanced form settings must round-trip through inspect → form → create
    /// body, and clearing them in Edit & Recreate must really clear them.
    private static func advancedSettings() {
        let inspect: [String: Any] = [
            "Id": "abcdef0123456789",
            "Config": [
                "Image": "nginx",
                "Hostname": "web-01",
                "Healthcheck": ["Test": ["CMD-SHELL", "curl -f localhost"],
                                "Interval": 30_000_000_000, "Retries": 3],
            ] as [String: Any],
            "HostConfig": [
                "Dns": ["1.1.1.1"],
                "ExtraHosts": ["db.local:10.0.0.5"],
                "CapAdd": ["CAP_NET_ADMIN"],
                "CapDrop": ["MKNOD"],
                "Init": true,
                "ShmSize": 268_435_456,
                "Devices": [["PathOnHost": "/dev/fuse", "PathInContainer": "/dev/fuse", "CgroupPermissions": "rwm"]],
                "Sysctls": ["net.core.somaxconn": "1024"],
                "LogConfig": ["Type": "json-file", "Config": ["max-size": "10m"]],
            ] as [String: Any],
        ]
        let a = ContainerConfigBuilder.advancedFromInspect(inspect)
        expectEqual(a.hostname, "web-01", "adv: explicit hostname kept")
        expectEqual(a.capAdd, ["NET_ADMIN"], "adv: CAP_ prefix normalized")
        expectEqual(a.extraHostsText, "db.local=10.0.0.5", "adv: extra host prefill")
        expectEqual(a.shmSizeMiB, "256", "adv: shm size MiB")
        expectEqual(a.devicesText, "/dev/fuse", "adv: simple device collapses to one path")
        expectEqual(a.healthCommand, "curl -f localhost", "adv: health command")
        expectEqual(a.healthIntervalSeconds, "30", "adv: health interval seconds")

        var form = RunContainerForm()
        form.image = "nginx"
        form.advanced = a
        let body = ContainerConfigBuilder.buildCreateConfig(form)
        let host = body["HostConfig"] as? [String: Any] ?? [:]
        expectEqual(host["ExtraHosts"] as? [String], ["db.local:10.0.0.5"], "adv: extra host emitted host:ip")
        expectEqual(host["ShmSize"] as? Int, 268_435_456, "adv: shm size bytes")
        expectEqual((host["LogConfig"] as? [String: Any])?["Type"] as? String, "json-file", "adv: log driver")
        let health = body["Healthcheck"] as? [String: Any]
        expectEqual(health?["Interval"] as? Int, 30_000_000_000, "adv: health interval ns")

        // Default docker hostname (id prefix) must not be pinned into edits.
        var defaulted = inspect
        defaulted["Config"] = ["Hostname": "abcdef012345"]
        expect(ContainerConfigBuilder.advancedFromInspect(defaulted).hostname.isEmpty,
               "adv: default hostname not prefilled")

        // Clearing in Edit & Recreate really clears.
        var cleared = ContainerConfigBuilder.formFromInspect(inspect)
        cleared.advanced.capAdd = []
        cleared.advanced.healthCommand = ""
        let merged = ContainerConfigBuilder.mergeForEdit(base: inspect, form: cleared)
        expectEqual((merged["HostConfig"] as? [String: Any])?["CapAdd"] as? [String], [],
                    "adv: cleared caps overwrite old ones")
        expect(merged["Healthcheck"] == nil, "adv: cleared health check falls back to image")
    }

    /// Monitor tab parsers: guest /proc sample, CPU% from jiffy deltas, and
    /// the /system/df breakdown (sizes + reclaimable).
    private static func monitorParsing() {
        let output = """
        cpu  100 0 50 800 50 0 0 0 0 0
        MemTotal:        2013580 kB
        MemAvailable:     705024 kB
        Cached:           419840 kB
        LOAD 0.92 0.61 0.33 2/155 4021
        UPTIME 186340.22
        DISK /dev/vda2 66055168 21471232 44583936 33% /
        """
        guard let first = MonitorParse.guestSnapshot(from: output) else {
            expect(false, "guest snapshot parsed")
            return
        }
        expectEqual(first.totalJiffies, 1000, "guest total jiffies")
        expectEqual(first.busyJiffies, 150, "guest busy jiffies (idle+iowait excluded)")
        expectEqual(first.memTotalKiB, 2_013_580, "guest mem total")
        expectEqual(first.diskSizeKiB, 66_055_168, "guest disk size")
        expect(abs(first.load1 - 0.92) < 0.001, "guest load1")

        var second = first
        second.totalJiffies += 400
        second.busyJiffies += 100
        expect(abs(MonitorParse.cpuPercent(previous: first, current: second) - 25) < 0.001,
               "cpu percent from jiffy delta")
        expectEqual(MonitorParse.cpuPercent(previous: second, current: first), 0,
                    "counter reset → 0, not negative")

        expect(abs(MonitorParse.rate(1000, 4000, seconds: 3) - 1000) < 0.001, "byte rate per second")

        let df: [String: Any] = [
            "LayersSize": 9_600_000_000,
            "Images": [["Size": 5_200_000_000, "Containers": 0], ["Size": 2_000_000_000, "Containers": 2]],
            "Containers": [["SizeRw": 4_500_000_000]],
            "Volumes": [["UsageData": ["Size": 3_800_000_000, "RefCount": 0]]],
            "BuildCache": [["Size": 1_700_000_000, "InUse": false]],
        ]
        let breakdown = MonitorParse.diskBreakdown(from: df)
        expectEqual(breakdown.imagesBytes, 9_600_000_000, "df images = LayersSize")
        expectEqual(breakdown.imagesReclaimable, 5_200_000_000, "df reclaimable = unreferenced images")
        expectEqual(breakdown.volumesReclaimable, 3_800_000_000, "df volume refcount 0 reclaimable")
        expectEqual(breakdown.buildCacheReclaimable, 1_700_000_000, "df build cache not in use")
        expectEqual(breakdown.totalBytes, 19_600_000_000, "df total sums categories")
    }

    /// Cleanup panel plumbing: docker's SpaceReclaimed parses in both integer
    /// and float form, and the images filter widens prune beyond dangling.
    private static func cleanupPrune() {
        expectEqual(DockerAPIClient.spaceReclaimed(Data(#"{"SpaceReclaimed": 1234567}"#.utf8)),
                    1_234_567, "prune SpaceReclaimed int")
        expectEqual(DockerAPIClient.spaceReclaimed(Data(#"{"SpaceReclaimed": 2.5e9}"#.utf8)),
                    2_500_000_000, "prune SpaceReclaimed float form")
        expectEqual(DockerAPIClient.spaceReclaimed(Data(#"{"NetworksDeleted": []}"#.utf8)),
                    0, "prune without SpaceReclaimed → 0")
        expectEqual(DockerAPIClient.unusedImagesFilter.removingPercentEncoding,
                    #"{"dangling":["false"]}"#, "unused-images filter decodes to docker syntax")
    }

    /// Sparse-image accounting: the reclaim UI reports decimal GB like Finder,
    /// and a sparse file must show allocated < apparent.
    private static func diskUsage() {
        expectEqual(DiskUsage.format(22_100_000_000), "22.1 GB", "disk usage decimal GB")
        expectEqual(DiskUsage.format(0), "0.0 GB", "disk usage zero")

        // Real sparse file: 8 MB long, nothing allocated beyond metadata.
        let sparse = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockz-sparse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sparse) }
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: sparse) {
            try? handle.truncate(atOffset: 8 * 1024 * 1024)
            try? handle.close()
        }
        expectEqual(DiskUsage.apparentBytes(at: sparse), 8 * 1024 * 1024, "apparent = logical length")
        expect((DiskUsage.allocatedBytes(at: sparse) ?? .max) < 8 * 1024 * 1024,
               "sparse file allocates less than its length")
    }

    /// A container joined to several networks must list them all, sorted, and
    /// surface a usable IP even when the top-level IPAddress is empty.
    private static func containerNetworks() {
        let detail = ContainerDetail(dict: [
            "Name": "/web",
            "NetworkSettings": [
                "IPAddress": "",
                "Networks": [
                    "frontend": ["IPAddress": "172.20.0.5"],
                    "backend": ["IPAddress": "172.21.0.5"],
                    "empty-net": [:],
                ],
            ] as [String: Any],
        ])
        expectEqual(detail.networks.map(\.name), ["backend", "empty-net", "frontend"],
                    "joined networks sorted")
        expectEqual(detail.networks.first?.ipAddress, "172.21.0.5", "per-network IP parsed")
        expect(!detail.ipAddress.isEmpty, "fallback IP picked from joined networks")
    }

    /// The provision script drives the setup progress bar via console markers.
    private static func buildStepMarkers() {
        let first = ImageBuilderCLI.parseStepMarker(">>> DOCKZ-STEP:1/7:installing builder tools")
        expectEqual(first?.label, "installing builder tools", "step marker label")
        expect((first?.fraction ?? 0) > 0.25, "step 1 past the provisioning floor")

        let last = ImageBuilderCLI.parseStepMarker(">>> DOCKZ-STEP:7/7:building initramfs + bootloader")
        expect((last?.fraction ?? 0) <= 0.93, "final step stays under the install phase")
        expect((last?.fraction ?? 0) > (first?.fraction ?? 1), "markers advance monotonically")

        // A label may contain colons; only the first separates it from the counts.
        expectEqual(ImageBuilderCLI.parseStepMarker(">>> DOCKZ-STEP:4/7:downloading a:b")?.label,
                    "downloading a:b", "label keeps embedded colons")

        // `set -x` echoes the echo itself — that line must not move the bar.
        expect(ImageBuilderCLI.parseStepMarker("+ echo '>>> DOCKZ-STEP:1/7:x'") == nil,
               "xtrace echo of the marker is ignored")
        expect(ImageBuilderCLI.parseStepMarker("random kernel noise") == nil, "non-marker ignored")
        expect(ImageBuilderCLI.parseStepMarker(">>> DOCKZ-STEP:bad") == nil, "malformed marker ignored")
        expect(ImageBuilderCLI.parseStepMarker(">>> DOCKZ-STEP:1/0:x") == nil, "zero total ignored")

        // Serial console progress lines carry ANSI escapes that must be stripped.
        expectEqual(SerialExpect.sanitize("\u{1B}[0K(31/86) Installing containerd"),
                    "(31/86) Installing containerd", "CSI clear-line stripped")
        expectEqual(SerialExpect.sanitize("\u{1B}7 42% \u{1B}8done"), "42% done", "ESC 7/8 cursor codes stripped")
        expectEqual(SerialExpect.sanitize("plain text"), "plain text", "plain text untouched")
        expectEqual(SerialExpect.sanitize("\u{1B}[1;32mgreen\u{1B}[0m"), "green", "SGR color codes stripped")

        // Full wiring: bytes through a real pipe → SerialExpect → onLine →
        // parseStepMarker, with the exact line endings the serial console uses
        // and a chunk boundary in the middle of a marker.
        let pipe = Pipe()
        var lines: [String] = []
        let linesLock = NSLock()
        let expecter = SerialExpect(
            readHandle: pipe.fileHandleForReading,
            writeHandle: pipe.fileHandleForWriting,
            logURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("dockz-test-serial-\(getpid()).log"),
            onLine: { line in
                linesLock.lock(); lines.append(line); linesLock.unlock()
            }
        )
        // The handler holds `self` weakly — the instance must outlive the drain.
        withExtendedLifetime(expecter) {
            let chunks = [
                "+ echo '>>> DOCKZ-STEP:1/7:installing builder tools'\r\n",
                ">>> DOCKZ-STEP:1/7:install",          // marker split across reads
                "ing builder tools\r\n",
                "\u{1B}[0K(31/86) Installing containerd\r",
                "\n>>> DOCKZ-STEP:4/7:downloading Alpine base + docker (longest step)\r\n",
            ]
            for chunk in chunks { pipe.fileHandleForWriting.write(Data(chunk.utf8)) }
            // readabilityHandler delivers on a background queue; give it a moment.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                linesLock.lock(); let count = lines.count; linesLock.unlock()
                if count >= 4 { break }
                usleep(20_000)
            }
        }
        linesLock.lock(); let received = lines; linesLock.unlock()
        expectEqual(received.count, 4, "pipe wiring emits each console line once")
        let markers = received.compactMap { ImageBuilderCLI.parseStepMarker($0) }
        expectEqual(markers.count, 2, "both real markers parsed from the pipe stream")
        expectEqual(markers.first?.label, "installing builder tools", "pipe marker label")
    }

    /// The zshrc block must append once, remove cleanly, and never clobber the
    /// user's own rc content around it.
    private static func shellIntegration() {
        let block = ShellIntegrationInstaller.block()
        expect(block.contains("command -v docker"),
               "shell block defers to a system docker")

        let rc = "export EDITOR=vim\nalias ll='ls -la'"
        let added = ShellIntegrationInstaller.adding(to: rc, block: block)
        expect(added.hasPrefix(rc), "user rc content preserved before the block")
        expect(added.contains(ShellIntegrationInstaller.beginMarker), "block appended")
        expectEqual(ShellIntegrationInstaller.adding(to: added, block: block), added,
                    "second add is a no-op")

        // A single trailing newline may remain — standard for rc files.
        expectEqual(ShellIntegrationInstaller.removing(from: added), rc + "\n",
                    "remove restores the original rc content")
        expectEqual(ShellIntegrationInstaller.removing(from: rc), rc,
                    "remove without a block is a no-op")
        expectEqual(ShellIntegrationInstaller.adding(to: "", block: block), block + "\n",
                    "empty rc gets just the block")

        let zshrc = ShellIntegrationInstaller.rcFileURL(
            shellPath: "/bin/zsh", home: URL(fileURLWithPath: "/Users/x"))
        expectEqual(zshrc.lastPathComponent, ".zshrc", "zsh → .zshrc")
        let bash = ShellIntegrationInstaller.rcFileURL(
            shellPath: "/opt/homebrew/bin/bash", home: URL(fileURLWithPath: "/Users/x"))
        expectEqual(bash.lastPathComponent, ".bash_profile", "bash → .bash_profile")
        let fish = ShellIntegrationInstaller.rcFileURL(
            shellPath: "/usr/local/bin/fish", home: URL(fileURLWithPath: "/Users/x"))
        expectEqual(fish.lastPathComponent, ".profile", "other shells → .profile")
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
