import Foundation

/// Detail-page and engine-config state (extends the dashboard store).
extension DashboardStore {
    // MARK: - Container detail

    func openDetail(for container: ContainerSummary) {
        selectedContainer = container
        containerDetail = nil
        containerStats = nil
        detailInspectJSON = ""
        detailLogs = ""
        reloadDetail()
    }

    func closeDetail() {
        selectedContainer = nil
    }

    // MARK: - Clean up

    /// What the cleanup panel may prune. Volumes hold user data and stopped
    /// containers may be restarted later, so those default to off.
    struct CleanupOptions {
        var unusedImages = true
        var buildCache = true
        var stoppedContainers = false
        var unusedNetworks = false
        var unusedVolumes = false
    }

    /// Prunes the selected categories in sequence, totals docker's
    /// SpaceReclaimed, then runs the disk reclaim so the freed blocks actually
    /// return to the Mac (prune alone only frees space inside the VM).
    func cleanUp(_ options: CleanupOptions) {
        guard !cleanupBusy else { return }
        guard let api = apiProvider() else {
            cleanupResult = "Engine offline — start the VM first."
            return
        }
        cleanupBusy = true
        cleanupResult = ""

        var steps: [(label: String, path: String)] = []
        if options.stoppedContainers { steps.append(("stopped containers", "/containers/prune")) }
        if options.unusedImages {
            steps.append(("unused images", "/images/prune?filters=\(DockerAPIClient.unusedImagesFilter)"))
        }
        if options.buildCache { steps.append(("build cache", "/build/prune?all=1")) }
        if options.unusedNetworks { steps.append(("unused networks", "/networks/prune")) }
        if options.unusedVolumes { steps.append(("unused volumes", "/volumes/prune")) }

        var remaining = steps
        var totalBytes: UInt64 = 0
        var firstError: String?
        func next() {
            guard let step = remaining.first else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.cleanupBusy = false
                    self.cleanupResult = firstError.map { "Cleanup ran with an error: \($0)" }
                        ?? "Freed \(DiskUsage.format(totalBytes)) inside the VM — reclaiming for your Mac…"
                    self.refreshAll()
                    // Give the space back to the host in the same click.
                    if firstError == nil { self.reclaimDiskSpace() }
                }
                return
            }
            remaining.removeFirst()
            api.prune(step.path) { error, reclaimed in
                totalBytes += reclaimed
                if let error, firstError == nil { firstError = "\(step.label): \(error)" }
                next()
            }
        }
        next()
    }

    // MARK: - Disk reclaim

    /// Blocks freed inside the VM (deleted images, pruned build cache) stay
    /// allocated in the sparse disk.img until the guest TRIMs them. `fstrim`
    /// issues virtio discards and APFS punches the holes — measured 27 → 22 GB
    /// on a real image (2026-09-21). Safe while docker runs; no restart needed.
    func reclaimDiskSpace() {
        guard !reclaimBusy else { return }
        guard let connect = shellProvider() else {
            reclaimResult = "Engine offline — start the VM first."
            return
        }
        reclaimBusy = true
        reclaimResult = ""
        let image = DockzPaths().diskImage
        let before = DiskUsage.allocatedBytes(at: image) ?? 0
        GuestShellRunner.run(script: "fstrim -v /", connect: connect) { [weak self] output in
            // Hole punching trails the discards slightly; measure after a beat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                self.reclaimBusy = false
                guard output != nil else {
                    self.reclaimResult = "Could not reach the guest shell."
                    return
                }
                let after = DiskUsage.allocatedBytes(at: image) ?? before
                let freed = before > after ? before - after : 0
                self.reclaimResult = freed > 0
                    ? "Freed \(DiskUsage.format(freed)) — now \(DiskUsage.format(after)) on your Mac."
                    : "Nothing to reclaim — already compact (\(DiskUsage.format(after)) on your Mac)."
            }
        }
    }

    // MARK: - Network membership (multi-network containers)

    func connectNetwork(_ networkName: String, container: ContainerSummary) {
        run(busyKey: container.id) { api, done in
            api.connectNetwork(networkName, containerID: container.id, completion: done)
        }
    }

    func disconnectNetwork(_ networkName: String, container: ContainerSummary) {
        run(busyKey: container.id) { api, done in
            api.disconnectNetwork(networkName, containerID: container.id, completion: done)
        }
    }

    func reloadDetail() {
        guard let api = apiProvider(), let container = selectedContainer else { return }
        let id = container.id
        api.inspectContainer(id: id) { [weak self] detail in
            DispatchQueue.main.async { self?.containerDetail = detail }
        }
        api.containerStats(id: id) { [weak self] stats in
            DispatchQueue.main.async { self?.containerStats = stats }
        }
        api.inspectContainerRaw(id: id) { [weak self] json in
            DispatchQueue.main.async { self?.detailInspectJSON = json }
        }
        api.fetchLogs(id: id) { [weak self] logs in
            DispatchQueue.main.async { self?.detailLogs = logs }
        }
    }

    // MARK: - Image detail

    func openImageDetail(_ image: ImageSummary) {
        guard let api = apiProvider() else { return }
        api.inspectImage(id: image.id) { [weak self] json in
            DispatchQueue.main.async {
                self?.imageInspect = ImageInspectPayload(id: image.id, title: image.repoTag, json: json)
            }
        }
    }

    // MARK: - Base system info (Settings page)

    func loadBaseSystemInfo() {
        guard let connect = shellProvider() else {
            baseSystem = [:]
            return
        }
        let script = """
        . /etc/os-release 2>/dev/null; echo "os=$PRETTY_NAME"
        echo "kernel=$(uname -r) ($(uname -m))"
        echo "docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unavailable)"
        echo "containerd=$(containerd --version 2>/dev/null | awk '{print $3}')"
        df -h / 2>/dev/null | awk 'NR==2 {print "disk="$3" used of "$2" ("$5")"}'
        free -m 2>/dev/null | awk 'NR==2 {printf "memory=%d MiB used of %d MiB\\n", $3, $2}'
        echo "uptime=$(uptime 2>/dev/null | sed 's/.*up[[:space:]]*//; s/,[[:space:]]*[0-9]*[[:space:]]*users.*//; s/,[[:space:]]*load.*//')"
        """
        GuestShellRunner.run(script: script, connect: connect) { [weak self] output in
            DispatchQueue.main.async {
                guard let self, let output else { return }
                var info: [String: String] = [:]
                for line in output.split(separator: "\n") {
                    guard let equals = line.firstIndex(of: "=") else { continue }
                    let key = String(line[..<equals])
                    let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { info[key] = value }
                }
                self.baseSystem = info
            }
        }
    }

    // MARK: - Engine config (daemon.json inside the guest)

    func loadEngineConfig() {
        guard let connect = shellProvider() else {
            engineConfigText = ""
            engineStatus = "Engine offline"
            return
        }
        engineStatus = "Loading…"
        GuestShellRunner.run(
            script: "cat /etc/docker/daemon.json 2>/dev/null || echo '{}'",
            connect: connect
        ) { [weak self] output in
            DispatchQueue.main.async {
                guard let self else { return }
                self.engineConfigText = output?.isEmpty == false ? output! : "{}"
                self.engineStatus = output == nil ? "Could not read daemon.json" : ""
            }
        }
    }

    func applyEngineConfig() {
        guard let connect = shellProvider() else { return }
        let text = engineConfigText
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            engineStatus = "Invalid JSON — not applied"
            return
        }
        engineStatus = "Applying (dockerd restarts)…"
        let encoded = data.base64EncodedString()
        let script = """
        echo \(encoded) | base64 -d > /etc/docker/daemon.json
        rc-service docker restart >/dev/null 2>&1
        sleep 2
        rc-service docker status | head -n1
        """
        GuestShellRunner.run(script: script, connect: connect) { [weak self] output in
            DispatchQueue.main.async {
                self?.engineStatus = output.map { "daemon.json applied — \($0)" } ?? "Apply failed (see console.log)"
                self?.refreshAll()
            }
        }
    }
}
