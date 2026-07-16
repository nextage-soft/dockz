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
