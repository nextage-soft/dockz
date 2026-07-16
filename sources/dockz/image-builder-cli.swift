import Foundation

/// `Dockz build-image [--force]` — builds ~/.dockz/disk.img from scratch by
/// booting an Alpine netboot VM (Virtualization.framework only, no Docker).
enum ImageBuilderCLI {
    static let alpineVersion = "v3.22"
    static var alpineNetbootBase: String {
        "https://dl-cdn.alpinelinux.org/alpine/\(alpineVersion)/releases/aarch64/netboot"
    }
    static var alpineRepoURL: String {
        "https://dl-cdn.alpinelinux.org/alpine/\(alpineVersion)/main"
    }
    static var alpineModloopURL: String { "\(alpineNetbootBase)/modloop-virt" }

    static func run(force: Bool) -> Never {
        DispatchQueue.global().async {
            do {
                try build(force: force)
                print("dockz: disk image ready at \(DockzPaths().diskImage.path)")
                exit(0)
            } catch {
                print("dockz: image build FAILED — \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func build(force: Bool) throws {
        let paths = DockzPaths()
        try paths.ensureBaseDirectory()
        if paths.diskImageExists && !force {
            throw DockzError.socketSetupFailed(
                "\(paths.diskImage.path) already exists (holds your docker data); re-run with --force to wipe and rebuild")
        }
        let limitGB = max(DockzSettings.load(from: paths).diskLimitGB, 8)
        try buildDiskImage(BuildRequest(
            outputURL: paths.diskImage,
            sizeGB: limitGB,
            profile: "docker",
            publicKey: nil,
            progress: { print("dockz: \($0)") }
        ))
    }

    struct BuildRequest {
        var outputURL: URL
        var sizeGB: Int
        var profile: String     // "docker" | "machine"
        var publicKey: String?
        var progress: ((String) -> Void)?
    }

    /// Provisions a bootable Alpine disk image by driving a netboot VM over
    /// its serial console. Blocking — run on a background thread from GUI.
    static func buildDiskImage(_ request: BuildRequest) throws {
        let paths = DockzPaths()
        try paths.ensureBaseDirectory()
        guard let guestDir = locateGuestDirectory() else {
            throw DockzError.socketSetupFailed("guest/ directory not found (looked in app Resources and current directory)")
        }
        let progress = request.progress ?? { _ in }

        let builderDir = paths.baseDirectory.appendingPathComponent("builder", isDirectory: true)
        try FileManager.default.createDirectory(at: builderDir, withIntermediateDirectories: true)
        progress("fetching Alpine \(alpineVersion) netboot kernel/initramfs…")
        let kernel = try fetchDecompressedKernel(into: builderDir)
        let initrd = try fetch("initramfs-virt", into: builderDir)

        let workDisk = request.outputURL.appendingPathExtension("building")
        try createSparseFile(at: workDisk, size: UInt64(max(request.sizeGB, 4)) * 1024 * 1024 * 1024)

        progress("booting builder VM (Alpine netboot)…")
        let vm = BuilderVM()
        let expect = SerialExpect(
            readHandle: vm.consoleReadHandle,
            writeHandle: vm.consoleWriteHandle,
            logURL: builderDir.appendingPathComponent("build.log")
        )
        try vm.start(kernel: kernel, initrd: initrd, disk: workDisk, guestDir: guestDir)

        do {
            try expect.expect(["login:"], timeout: 240)
            expect.sendLine("root")
            try expect.expect(["# "], timeout: 30)
            progress("provisioning \(request.profile) profile (installs Alpine onto the disk; a few minutes)…")
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var environment = "SHARE_PATH=\(home) PROFILE=\(request.profile)"
            if let key = request.publicKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                environment += " PUBKEY='\(key)'"
            }
            expect.sendLine("modprobe virtiofs; mkdir -p /w; mount -t virtiofs dockzsrc /w && "
                + "\(environment) sh /w/provision-inside-vm.sh")
            try expect.expect(["DOCKZ-PROVISION-DONE"], timeout: 1500)
        } catch {
            vm.forceStop()
            throw error
        }

        guard vm.waitForShutdown(timeout: 120) else {
            vm.forceStop()
            throw DockzError.socketSetupFailed("builder VM did not power off after provisioning")
        }

        progress("installing image…")
        _ = try? FileManager.default.removeItem(at: request.outputURL)
        try FileManager.default.moveItem(at: workDisk, to: request.outputURL)
        progress("image ready at \(request.outputURL.path)")
    }

    // MARK: - Helpers

    private static func locateGuestDirectory() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("guest", isDirectory: true))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("guest", isDirectory: true))
        candidates.append(cwd) // invoked from inside guest/
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("provision-inside-vm.sh").path)
        }
    }

    private static func fetch(_ name: String, into directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let url = URL(string: "\(alpineNetbootBase)/\(name)") else {
            throw DockzError.socketSetupFailed("bad URL for \(name)")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error> = .failure(DockzError.socketSetupFailed("download did not complete"))
        URLSession.shared.downloadTask(with: url) { temporary, _, error in
            if let temporary {
                result = Result { try FileManager.default.moveItem(at: temporary, to: destination); return destination }
            } else {
                result = .failure(error ?? DockzError.socketSetupFailed("download failed: \(name)"))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }

    /// VZLinuxBootLoader needs an uncompressed arm64 kernel. Alpine ships an
    /// EFI zboot PE ("MZ" + "zimg", gzip payload at the offset stored in the
    /// header) — older releases were plain gzip. Handle both.
    private static func fetchDecompressedKernel(into directory: URL) throws -> URL {
        let plain = directory.appendingPathComponent("vmlinux-virt")
        if FileManager.default.fileExists(atPath: plain.path) { return plain }
        let compressed = try fetch("vmlinuz-virt", into: directory)
        let data = try Data(contentsOf: compressed)

        var gzipPayload: Data
        if data.count > 16, data[0] == 0x4d, data[1] == 0x5a,
           data[4...7] == Data("zimg".utf8) {
            let offset = Int(data[8]) | Int(data[9]) << 8 | Int(data[10]) << 16 | Int(data[11]) << 24
            let size = Int(data[12]) | Int(data[13]) << 8 | Int(data[14]) << 16 | Int(data[15]) << 24
            guard offset + size <= data.count else {
                throw DockzError.socketSetupFailed("corrupt zboot header in vmlinuz-virt")
            }
            gzipPayload = data.subdata(in: offset..<(offset + size))
        } else {
            gzipPayload = data
        }
        guard gzipPayload.count > 2, gzipPayload[0] == 0x1f, gzipPayload[1] == 0x8b else {
            // Not compressed at all — use as-is.
            try data.write(to: plain)
            return plain
        }

        let temporary = directory.appendingPathComponent("kernel-payload.gz")
        try gzipPayload.write(to: temporary)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", temporary.path]
        FileManager.default.createFile(atPath: plain.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: plain)
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: temporary)
        guard process.terminationStatus == 0, (try? plain.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 4096 else {
            throw DockzError.socketSetupFailed("could not extract kernel from vmlinuz-virt")
        }
        return plain
    }

    private static func createSparseFile(at url: URL, size: UInt64) throws {
        _ = try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
    }
}
