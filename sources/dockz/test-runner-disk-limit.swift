import Foundation

/// The disk limit must be enforced both ways: a lowered limit used to be
/// ignored (the image only ever grew), so the VM kept using more than allowed.
extension TestRunner {
    static func diskLimit() {
        let gib = DiskLimit.bytesPerGB

        // Direction of the change, with the 8 GB floor every creator uses.
        expectEqual(DiskLimit.change(currentBytes: 64 * gib, limitGB: 16), .shrink(toBytes: 16 * gib),
                    "disk limit: lowered limit shrinks")
        expectEqual(DiskLimit.change(currentBytes: 16 * gib, limitGB: 64), .grow(toBytes: 64 * gib),
                    "disk limit: raised limit grows")
        expectEqual(DiskLimit.change(currentBytes: 32 * gib, limitGB: 32), .none, "disk limit: equal is no change")
        expectEqual(DiskLimit.change(currentBytes: 16 * gib, limitGB: 2), .shrink(toBytes: 8 * gib),
                    "disk limit: never below the 8 GB floor")

        // Headroom: 10% of the new size, at least 1 GiB.
        expectEqual(DiskLimit.headroomBytes(forTarget: 8 * gib), gib, "disk limit: headroom floor")
        expectEqual(DiskLimit.headroomBytes(forTarget: 100 * gib), 10 * gib, "disk limit: headroom 10%")

        // Suggested limit when the data does not fit: data + headroom + layout.
        expectEqual(DiskLimit.smallestLimitGB(forMinimumFilesystemBytes: 10 * gib), 16,
                    "disk limit: 10 GiB of data fits in 16")
        expectEqual(DiskLimit.smallestLimitGB(forMinimumFilesystemBytes: 14 * gib + gib / 2), 24,
                    "disk limit: 14.5 GiB of data needs 24")
        expect(DiskLimit.tooSmallMessage(minimumFilesystemBytes: 14 * gib + gib / 2, limitGB: 16)
                .contains("Choose 24 GB or more"), "disk limit: refusal names a limit that fits")

        // Room for the safety copy on the Mac.
        expect(DiskLimit.hostSpaceProblem(availableBytes: 20 * gib, imageAllocatedBytes: 14 * gib) == nil,
               "disk limit: enough Mac space")
        expect(DiskLimit.hostSpaceProblem(availableBytes: 10 * gib, imageAllocatedBytes: 14 * gib)?
                .contains("free on your Mac") == true, "disk limit: too little Mac space is explained")
        expect(DiskLimit.hostSpaceProblem(availableBytes: nil, imageAllocatedBytes: 14 * gib) == nil,
               "disk limit: unknown Mac space does not block")

        // Used-of-limit colours.
        expectEqual(DiskLimit.usageLevel(usedBytes: 8 * gib, limitBytes: 16 * gib), .normal, "disk usage: half")
        expectEqual(DiskLimit.usageLevel(usedBytes: 13 * gib, limitBytes: 16 * gib), .warning, "disk usage: ≥80%")
        expectEqual(DiskLimit.usageLevel(usedBytes: 20 * gib, limitBytes: 16 * gib), .critical,
                    "disk usage: over the limit is critical")
        expectEqual(DiskLimit.usageLevel(usedBytes: 1, limitBytes: 0), .normal, "disk usage: no limit known")

        // Console markers, as they arrive on a serial line (escape codes, \r).
        expectEqual(DiskShrinkMarker.parse("\u{1b}[0mDOCKZ-SHRINK-STEP:checking the filesystem\r"),
                    .step("checking the filesystem"), "shrink marker: step")
        expectEqual(DiskShrinkMarker.parse("DOCKZ-SHRINK-TOOSMALL:15569256448"),
                    .tooSmall(minimumBytes: 15_569_256_448), "shrink marker: too small")
        expectEqual(DiskShrinkMarker.parse("DOCKZ-SHRINK-FAIL:e2fsck: errors left"),
                    .failed("e2fsck: errors left"), "shrink marker: failure reason keeps its colons")
        expectEqual(DiskShrinkMarker.parse("DOCKZ-SHRINK-DONE"), .done, "shrink marker: done")
        expect(DiskShrinkMarker.parse("# TARGET_SECTORS=1 sh /w/shrink-disk-inside-vm.sh") == nil,
               "shrink marker: echoed command is not a marker")
        expect(!DiskShrinkMarker.step("x").isOutcome && DiskShrinkMarker.done.isOutcome,
               "shrink marker: steps are not outcomes")

        // The guest script prints every marker the host waits for.
        if let guest = ImageBuilderCLI.locateGuestDirectory(),
           let script = try? String(contentsOf: guest.appendingPathComponent("shrink-disk-inside-vm.sh"), encoding: .utf8) {
            for marker in ["DOCKZ-SHRINK-STEP:", "DOCKZ-SHRINK-FAIL:", "DOCKZ-SHRINK-TOOSMALL:", "DOCKZ-SHRINK-DONE",
                           "TARGET_SECTORS", "HEADROOM_BYTES"] {
                expect(script.contains(marker), "shrink script: uses \(marker)")
            }
        } else {
            expect(false, "shrink script: guest/shrink-disk-inside-vm.sh found")
        }

        // An interrupted shrink is undone from the safety copy, once.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dockz-shrink-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = folder.appendingPathComponent("disk.img")
        try? Data("half-shrunk".utf8).write(to: disk)
        try? Data("original".utf8).write(to: DiskShrinker.backupURL(for: disk))
        expect(DiskShrinker.recoverInterruptedShrink(disk: disk), "shrink recovery: restores the copy")
        expectEqual((try? String(contentsOf: disk, encoding: .utf8)) ?? "", "original", "shrink recovery: original back")
        expect(!FileManager.default.fileExists(atPath: DiskShrinker.backupURL(for: disk).path),
               "shrink recovery: copy consumed")
        expect(!DiskShrinker.recoverInterruptedShrink(disk: disk), "shrink recovery: nothing to do afterwards")
    }
}
