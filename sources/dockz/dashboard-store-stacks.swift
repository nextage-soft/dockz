import Foundation

/// Compose stacks: deploy/tear down compose files through the host docker CLI
/// (DOCKER_HOST pointed at the dockz socket) and group running containers by
/// their com.docker.compose.project label — Portainer-style.
struct StackEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var composePath: String
}

/// A row in the Stacks tab: saved file stacks merged with label-discovered ones.
struct StackRow: Identifiable {
    let name: String
    let composePath: String?
    let runningCount: Int
    let totalCount: Int

    var id: String { name }
}

extension DashboardStore {
    private var stacksFileURL: URL {
        DockzPaths().baseDirectory.appendingPathComponent("stacks.json")
    }

    func loadStackFiles() {
        guard let data = try? Data(contentsOf: stacksFileURL),
              let list = try? JSONDecoder().decode([StackEntry].self, from: data) else { return }
        stackFiles = list
    }

    private func saveStackFiles() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(stackFiles) {
            try? data.write(to: stacksFileURL)
        }
    }

    func addStackFile(name: String, composePath: String) {
        if let index = stackFiles.firstIndex(where: { $0.name == name }) {
            stackFiles[index].composePath = composePath
        } else {
            stackFiles.append(StackEntry(name: name, composePath: composePath))
        }
        saveStackFiles()
    }

    func removeStackFile(named name: String) {
        stackFiles.removeAll { $0.name == name }
        saveStackFiles()
    }

    /// Saved stacks merged with any compose projects discovered from labels.
    var stackRows: [StackRow] {
        var byProject: [String: [ContainerSummary]] = [:]
        for container in containers {
            guard let project = container.composeProject else { continue }
            byProject[project, default: []].append(container)
        }
        var rows: [StackRow] = []
        var seen = Set<String>()
        for entry in stackFiles {
            let members = byProject[entry.name] ?? []
            rows.append(StackRow(
                name: entry.name,
                composePath: entry.composePath,
                runningCount: members.filter(\.isRunning).count,
                totalCount: members.count
            ))
            seen.insert(entry.name)
        }
        for (project, members) in byProject where !seen.contains(project) {
            rows.append(StackRow(
                name: project,
                composePath: nil,
                runningCount: members.filter(\.isRunning).count,
                totalCount: members.count
            ))
        }
        return rows.sorted { $0.name < $1.name }
    }

    func containers(inStack name: String) -> [ContainerSummary] {
        containers.filter { $0.composeProject == name }
    }

    /// Saves editor-authored YAML into the app-managed stacks folder and
    /// deploys it. Existing stacks keep their own compose path.
    func deployStackFromEditor(name: String, yaml: String, existingPath: String?) {
        let path: String
        if let existingPath {
            path = existingPath
        } else {
            let directory = DockzPaths().baseDirectory
                .appendingPathComponent("stacks", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("compose.yaml").path
        }
        do {
            try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Could not save compose file: \(error.localizedDescription)"
            return
        }
        addStackFile(name: name, composePath: path)
        stackUp(name: name, composePath: path)
    }

    // MARK: - Compose commands

    func stackUp(name: String, composePath: String) {
        runCompose(title: "up — \(name)", arguments: ["compose", "-f", composePath, "-p", name, "up", "-d", "--remove-orphans"])
    }

    func stackDown(name: String) {
        runCompose(title: "down — \(name)", arguments: ["compose", "-p", name, "down"])
    }

    private func runCompose(title: String, arguments: [String]) {
        guard !composeRunning else { return }
        guard let docker = DockerCLI.resolve() else {
            lastError = "Docker CLI not found. Install it from Settings → Docker CLI."
            return
        }
        composeRunning = true
        composeTitle = title
        composeOutput = "$ docker \(arguments.joined(separator: " "))\n\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker.path)
        process.arguments = arguments
        process.environment = DockerCLI.environment(for: docker,
                                                    socketPath: DockzPaths().dockerSocket.path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.composeOutput += text }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.composeOutput += finished.terminationStatus == 0
                    ? "\n✓ done"
                    : "\n✗ exited with status \(finished.terminationStatus)"
                self.composeRunning = false
                self.refreshAll()
            }
        }
        do {
            try process.run()
        } catch {
            composeOutput += "failed to launch docker CLI: \(error.localizedDescription)"
            composeRunning = false
        }
    }
}
