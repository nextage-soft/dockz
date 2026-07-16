import Foundation

/// Base image catalog: build/download per-distro base images (all ARM64) and
/// create machines as APFS clones of them. Alpine is built from scratch via
/// netboot; Debian/Ubuntu are downloaded cloud images seeded with cloud-init.
extension MachineManager {
    private var basesFile: URL { basesDir.appendingPathComponent("bases.json") }

    func baseImagePath(_ id: String) -> URL {
        basesDir.appendingPathComponent("\(id).img")
    }

    func loadBases() {
        if let data = try? Data(contentsOf: basesFile),
           let list = try? JSONDecoder().decode([MachineBase].self, from: data) {
            bases = list.filter { FileManager.default.fileExists(atPath: baseImagePath($0.id).path) }
        }
        // Migrate the legacy single Alpine base (~/.dockz/machines/.base-alpine.img).
        let legacy = machinesDir.appendingPathComponent(".base-alpine.img")
        if bases.isEmpty, FileManager.default.fileExists(atPath: legacy.path) {
            let target = baseImagePath("alpine-3.22")
            try? FileManager.default.createDirectory(at: basesDir, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: legacy, to: target)
            if FileManager.default.fileExists(atPath: target.path) {
                bases = [MachineBase(id: "alpine-3.22", displayName: "Alpine 3.22 (recommended)",
                                     family: "alpine", arch: "arm64", builtAt: "migrated")]
                saveBases()
            }
        }
    }

    private func saveBases() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(bases) {
            try? data.write(to: basesFile)
        }
    }

    func hasBase(_ id: String) -> Bool {
        bases.contains { $0.id == id }
    }

    func deleteBase(_ id: String) {
        try? FileManager.default.removeItem(at: baseImagePath(id))
        bases.removeAll { $0.id == id }
        saveBases()
    }

    // MARK: - Building bases

    func buildBase(distro: MachineDistro) {
        guard !buildingBase else { return }
        guard let publicKey = machineSSHPublicKey else {
            lastError = "Could not create the machines SSH key"
            return
        }
        buildingBase = true
        buildOutput = "Preparing \(distro.displayName) base (arm64)…\n"
        let output = baseImagePath(distro.id)

        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            do {
                switch distro.provisioning {
                case .netboot:
                    try ImageBuilderCLI.buildDiskImage(.init(
                        outputURL: output, sizeGB: 4, profile: "machine", publicKey: publicKey,
                        progress: { update in
                            DispatchQueue.main.async {
                                self.buildOutput += "==> [\(Int(update.fraction * 100))%] \(update.label)\n"
                            }
                        },
                        console: { line in DispatchQueue.main.async { self.buildOutput += line + "\n" } }
                    ))
                case .cloudImage(let rawURL, _, let isQcow2):
                    try self.downloadCloudImage(from: rawURL, to: output, isQcow2: isQcow2) { line in
                        DispatchQueue.main.async { self.buildOutput += line + "\n" }
                    }
                }
                DispatchQueue.main.async {
                    self.registerBase(distro)
                    self.buildingBase = false
                    self.baseImageReady = true
                    self.buildOutput += "✓ \(distro.displayName) base ready\n"
                }
            } catch {
                try? FileManager.default.removeItem(at: output)
                DispatchQueue.main.async {
                    self.buildingBase = false
                    self.buildOutput += "✗ failed: \(error.localizedDescription)\n"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func registerBase(_ distro: MachineDistro) {
        bases.removeAll { $0.id == distro.id }
        bases.append(MachineBase(id: distro.id, displayName: distro.displayName,
                                 family: distro.family, arch: "arm64", builtAt: "built"))
        bases.sort { $0.id < $1.id }
        saveBases()
    }

    /// Downloads a cloud image, converting qcow2 → raw when needed (qemu-img).
    private func downloadCloudImage(from urlString: String, to destination: URL, isQcow2: Bool, progress: @escaping (String) -> Void) throws {
        guard let url = URL(string: urlString) else {
            throw DockzError.socketSetupFailed("bad image URL")
        }
        progress("downloading \(url.lastPathComponent) (~hundreds of MB, cached)…")
        let temporary = destination.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: temporary)

        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?
        let task = URLSession.shared.downloadTask(with: url) { location, _, error in
            if let location {
                do { try FileManager.default.moveItem(at: location, to: temporary) }
                catch { downloadError = error }
            } else {
                downloadError = error ?? DockzError.socketSetupFailed("download failed")
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        if let downloadError { throw downloadError }

        if isQcow2 {
            progress("converting qcow2 → raw…")
            guard let qemuImg = findQemuImg() else {
                try? FileManager.default.removeItem(at: temporary)
                throw DockzError.socketSetupFailed("qcow2 image needs qemu-img — install with: brew install qemu")
            }
            let convert = Process()
            convert.executableURL = URL(fileURLWithPath: qemuImg)
            convert.arguments = ["convert", "-f", "qcow2", "-O", "raw", temporary.path, destination.path]
            try convert.run()
            convert.waitUntilExit()
            try? FileManager.default.removeItem(at: temporary)
            guard convert.terminationStatus == 0 else {
                throw DockzError.socketSetupFailed("qemu-img convert failed")
            }
        } else {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private func findQemuImg() -> String? {
        ["/opt/homebrew/bin/qemu-img", "/usr/local/bin/qemu-img"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
