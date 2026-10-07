import Darwin
import Foundation

/// Shrinks a stopped VM's disk image to a smaller limit, safely.
///
/// ext4 can only be shrunk unmounted, so the work runs in the netboot builder
/// VM (the one `build-image` uses) with the disk attached:
/// guest/shrink-disk-inside-vm.sh checks the filesystem, refuses if the data
/// would not fit with headroom, shrinks it, and rewrites the GPT for the new
/// size; the host then truncates the image. The image is APFS-cloned first and
/// the clone is put back on any failure — including DockZ quitting or crashing
/// mid-way (`recoverInterruptedShrink` runs before every VM start).
///
/// Works on any DockZ-layout disk (ESP + ext4 root as the last partition), so
/// machine disks can use it too. Blocking: call off the main thread.
enum DiskShrinker {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func backupURL(for disk: URL) -> URL {
        disk.appendingPathExtension("before-shrink")
    }

    /// Puts back the pre-shrink copy: after a failed shrink, or one cut short
    /// by DockZ quitting or crashing. Returns true when it did. Must not run
    /// while a shrink is in progress.
    @discardableResult
    static func recoverInterruptedShrink(disk: URL) -> Bool {
        let backup = backupURL(for: disk)
        guard FileManager.default.fileExists(atPath: backup.path) else { return false }
        guard rename(backup.path, disk.path) == 0 else {
            HostLog.write("disk shrink: could not restore \(backup.lastPathComponent) (errno \(errno))")
            return false
        }
        HostLog.write("disk shrink: safety copy put back — \(disk.lastPathComponent) is as it was before the shrink")
        return true
    }

    static func shrink(disk: URL, toBytes target: UInt64, limitGB: Int,
                       progress: @escaping (String) -> Void) throws {
        guard let current = DiskUsage.apparentBytes(at: disk), target < current else { return }
        guard target % 512 == 0 else { throw Failure(message: "The new size is not a whole number of sectors.") }
        recoverInterruptedShrink(disk: disk)

        let folder = disk.deletingLastPathComponent()
        if let problem = DiskLimit.hostSpaceProblem(
            availableBytes: DiskUsage.volumeAvailableBytes(at: folder),
            imageAllocatedBytes: DiskUsage.allocatedBytes(at: disk) ?? current) {
            throw Failure(message: problem)
        }
        guard let guestDir = ImageBuilderCLI.locateGuestDirectory(),
              FileManager.default.fileExists(atPath: guestDir.appendingPathComponent("shrink-disk-inside-vm.sh").path)
        else { throw Failure(message: "guest/shrink-disk-inside-vm.sh is missing from the app.") }

        progress("fetching the Alpine tools VM")
        let builderDir = DockzPaths().baseDirectory.appendingPathComponent("builder", isDirectory: true)
        try FileManager.default.createDirectory(at: builderDir, withIntermediateDirectories: true)
        let kernel = try ImageBuilderCLI.fetchDecompressedKernel(into: builderDir)
        let initrd = try ImageBuilderCLI.fetch("initramfs-virt", into: builderDir)

        let backup = backupURL(for: disk)
        guard clonefile(disk.path, backup.path, 0) == 0 else {
            throw Failure(message: "Could not make a safety copy of the disk (errno \(errno)).")
        }
        do {
            try runShrinkVM(disk: disk, targetBytes: target, limitGB: limitGB, kernel: kernel, initrd: initrd,
                            guestDir: guestDir, logURL: builderDir.appendingPathComponent("shrink.log"),
                            progress: progress)
            let handle = try FileHandle(forWritingTo: disk)
            try handle.truncate(atOffset: target)
            try handle.close()
        } catch {
            recoverInterruptedShrink(disk: disk)
            throw error
        }
        try? FileManager.default.removeItem(at: backup)
        HostLog.write("disk shrink: \(disk.lastPathComponent) \(DiskLimit.format(current)) → \(DiskLimit.format(target))")
    }

    private static func runShrinkVM(disk: URL, targetBytes: UInt64, limitGB: Int, kernel: URL, initrd: URL,
                                    guestDir: URL, logURL: URL, progress: @escaping (String) -> Void) throws {
        let outcomeLock = NSLock()
        var outcome: DiskShrinkMarker?
        progress("starting the tools VM")
        let vm = BuilderVM()
        let expect = SerialExpect(
            readHandle: vm.consoleReadHandle, writeHandle: vm.consoleWriteHandle, logURL: logURL,
            onLine: { line in
                guard let marker = DiskShrinkMarker.parse(line) else { return }
                if case .step(let label) = marker { progress(label); return }
                outcomeLock.lock(); outcome = marker; outcomeLock.unlock()
            })
        try vm.start(kernel: kernel, initrd: initrd, disk: disk, guestDir: guestDir)
        do {
            try expect.expect(["login:"], timeout: 240)
            expect.sendLine("root")
            try expect.expect(["# "], timeout: 30)
            let environment = "TARGET_SECTORS=\(targetBytes / 512) HEADROOM_BYTES=\(DiskLimit.headroomBytes(forTarget: targetBytes))"
            expect.sendLine("modprobe virtiofs; mkdir -p /w; mount -t virtiofs dockzsrc /w && "
                + "\(environment) sh /w/shrink-disk-inside-vm.sh")
            // resize2fs moves every block that sits past the new end; on a
            // large, full disk that is minutes of I/O.
            try expect.expect(["DOCKZ-SHRINK-DONE", "DOCKZ-SHRINK-FAIL:", "DOCKZ-SHRINK-TOOSMALL:"], timeout: 1800)
        } catch {
            vm.forceStop()
            throw Failure(message: "The disk tools VM did not finish (\(error.localizedDescription)). Details: \(logURL.path)")
        }
        guard vm.waitForShutdown(timeout: 120) else {
            vm.forceStop()
            throw Failure(message: "The disk tools VM did not power off. Details: \(logURL.path)")
        }
        outcomeLock.lock(); let result = outcome; outcomeLock.unlock()
        switch result {
        case .done?:
            return
        case .tooSmall(let minimum)?:
            throw Failure(message: DiskLimit.tooSmallMessage(minimumFilesystemBytes: minimum, limitGB: limitGB))
        case .failed(let reason)?:
            throw Failure(message: "Shrinking failed: \(reason). Details: \(logURL.path)")
        default:
            throw Failure(message: "The disk tools VM stopped without a result. Details: \(logURL.path)")
        }
    }
}
