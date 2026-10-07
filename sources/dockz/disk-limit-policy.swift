import Foundation

/// The disk limit is enforced by the size of the VM's sparse disk image: the
/// guest cannot store more than the image holds. Growing is a host truncate
/// plus the guest's dockz-resize service; shrinking needs the filesystem
/// shrunk offline first (DiskShrinker). Before this existed only growing was
/// done, so a lowered limit (16 GB on a 64 GB disk, seen in the field) was
/// silently ignored and the VM kept using more than the user allowed.
enum DiskLimit {
    /// The slider says "GB"; the image has always been sized in GiB.
    static let bytesPerGB: UInt64 = 1 << 30
    /// Smallest disk DockZ creates or shrinks to (Alpine + dockerd + room).
    static let minimumGB = 8

    static func bytes(forGB gb: Int) -> UInt64 { UInt64(max(gb, minimumGB)) * bytesPerGB }

    /// "10.1 GB" in the limit's own unit (GiB, labelled GB like the slider and
    /// Monitor), so sizes in one message compare directly with the limit.
    static func format(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / Double(bytesPerGB))
    }

    enum Change: Equatable {
        case none
        case grow(toBytes: UInt64)
        case shrink(toBytes: UInt64)
    }

    static func change(currentBytes: UInt64, limitGB: Int) -> Change {
        let target = bytes(forGB: limitGB)
        if currentBytes < target { return .grow(toBytes: target) }
        if currentBytes > target { return .shrink(toBytes: target) }
        return .none
    }

    /// Free space the shrunk filesystem must still have, so Docker is not
    /// left with a full disk right after the shrink: 10% of the new size,
    /// at least 1 GiB.
    static func headroomBytes(forTarget target: UInt64) -> UInt64 {
        max(bytesPerGB, target / 10)
    }

    /// Partition table, ESP (64 MiB) and 1 MiB alignment come out of the disk
    /// before the root filesystem; 1 GiB covers them with room to spare.
    static let layoutOverheadBytes: UInt64 = bytesPerGB

    /// Smallest slider value (a multiple of 8 GB) whose disk holds a
    /// filesystem of `minimumBytes` plus the headroom.
    static func smallestLimitGB(forMinimumFilesystemBytes minimumBytes: UInt64) -> Int {
        var gb = minimumGB
        while bytes(forGB: gb) < minimumBytes + headroomBytes(forTarget: bytes(forGB: gb)) + layoutOverheadBytes {
            gb += 8
        }
        return gb
    }

    /// The image is APFS-cloned before the shrink so any failure can be
    /// undone. The clone shares blocks; whatever resize2fs rewrites is copied
    /// on write, which is bounded by what the image has allocated. nil = fits.
    static func hostSpaceProblem(availableBytes: UInt64?, imageAllocatedBytes: UInt64) -> String? {
        guard let availableBytes else { return nil }
        let needed = imageAllocatedBytes + bytesPerGB
        guard availableBytes < needed else { return nil }
        return "Shrinking needs up to \(DiskUsage.format(needed)) free on your Mac for a safety copy of the disk; only \(DiskUsage.format(availableBytes)) is free."
    }

    static func tooSmallMessage(minimumFilesystemBytes: UInt64, limitGB: Int) -> String {
        let smallest = smallestLimitGB(forMinimumFilesystemBytes: minimumFilesystemBytes)
        return "Your Docker data needs about \(format(minimumFilesystemBytes)), which does not fit in \(limitGB) GB with room to spare. Choose \(smallest) GB or more, or remove unused images and volumes (Clean Up…, then Reclaim Free Space) and try again."
    }

    /// Colour level for "used of limit": warn at 80%, critical at 95%.
    enum UsageLevel: Equatable { case normal, warning, critical }

    static func usageLevel(usedBytes: UInt64, limitBytes: UInt64) -> UsageLevel {
        guard limitBytes > 0 else { return .normal }
        let fraction = Double(usedBytes) / Double(limitBytes)
        if fraction >= 0.95 { return .critical }
        if fraction >= 0.8 { return .warning }
        return .normal
    }
}

/// Console markers printed by guest/shrink-disk-inside-vm.sh.
enum DiskShrinkMarker: Equatable {
    case step(String)
    case done
    case tooSmall(minimumBytes: UInt64)
    case failed(String)

    static let prefix = "DOCKZ-SHRINK-"

    static func parse(_ line: String) -> DiskShrinkMarker? {
        guard let range = line.range(of: prefix) else { return nil }
        let body = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if body == "DONE" { return .done }
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "STEP": return .step(parts[1])
        case "FAIL": return .failed(parts[1])
        case "TOOSMALL": return UInt64(parts[1]).map { .tooSmall(minimumBytes: $0) }
        default: return nil
        }
    }

    var isOutcome: Bool {
        if case .step = self { return false }
        return true
    }
}
