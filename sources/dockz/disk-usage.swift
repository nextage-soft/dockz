import Foundation

/// Host-side view of the (sparse) VM disk image: how big it *looks* to the
/// guest (apparent size) versus how much APFS has actually allocated on the
/// Mac. Reclaiming space = `fstrim` in the guest → virtio discard → APFS
/// punches holes → allocated size drops; the apparent size never changes.
enum DiskUsage {
    /// Bytes APFS really allocated for the file (what the user's Mac loses).
    static func allocatedBytes(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return (values?.totalFileAllocatedSize).map(UInt64.init)
    }

    /// The file's logical length — the disk size the guest sees.
    static func apparentBytes(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return (values?.fileSize).map(UInt64.init)
    }

    /// "22.1 GB" — decimal GB to match what Finder shows the user.
    static func format(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    /// Human summary for the settings page; nil when the image is missing.
    static func summary(for url: URL) -> String? {
        guard let allocated = allocatedBytes(at: url), let apparent = apparentBytes(at: url) else {
            return nil
        }
        return "\(format(allocated)) used on your Mac · disk size \(format(apparent))"
    }
}
