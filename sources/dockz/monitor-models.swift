import Foundation

/// Pure parsing/derivation for the Monitor tab — kept free of I/O so the test
/// runner can cover it with fixtures.
enum MonitorParse {
    // MARK: - VM vitals (one guest-shell script, parsed by line shape)

    /// Raw counters from one guest sample. CPU% needs two of these (jiffies
    /// are cumulative since boot).
    struct GuestSnapshot: Equatable {
        var busyJiffies: UInt64
        var totalJiffies: UInt64
        var memTotalKiB: UInt64
        var memAvailableKiB: UInt64
        var cachedKiB: UInt64
        var load1: Double
        var uptimeSeconds: Double
        var diskUsedKiB: UInt64
        var diskSizeKiB: UInt64
    }

    /// Script sent over the vsock shell; each output line is recognised by its
    /// own shape, so ordering/prompt noise cannot mis-bind values.
    static let guestScript = """
    head -1 /proc/stat
    grep -E '^(MemTotal|MemAvailable|Cached):' /proc/meminfo
    echo "LOAD $(cat /proc/loadavg)"
    echo "UPTIME $(cut -d' ' -f1 /proc/uptime)"
    echo "DISK $(df -k / | tail -1)"
    """

    static func guestSnapshot(from output: String) -> GuestSnapshot? {
        var snapshot = GuestSnapshot(busyJiffies: 0, totalJiffies: 0, memTotalKiB: 0,
                                     memAvailableKiB: 0, cachedKiB: 0, load1: 0,
                                     uptimeSeconds: 0, diskUsedKiB: 0, diskSizeKiB: 0)
        var sawCPU = false
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            if fields.first == "cpu", fields.count >= 5 {
                // cpu user nice system idle iowait irq softirq …
                let values = fields.dropFirst().compactMap(UInt64.init)
                guard values.count >= 4 else { continue }
                let idle = values[3] + (values.count > 4 ? values[4] : 0)
                snapshot.totalJiffies = values.reduce(0, +)
                snapshot.busyJiffies = snapshot.totalJiffies - idle
                sawCPU = true
            } else if fields.first == "MemTotal:", fields.count >= 2 {
                snapshot.memTotalKiB = UInt64(fields[1]) ?? 0
            } else if fields.first == "MemAvailable:", fields.count >= 2 {
                snapshot.memAvailableKiB = UInt64(fields[1]) ?? 0
            } else if fields.first == "Cached:", fields.count >= 2 {
                snapshot.cachedKiB = UInt64(fields[1]) ?? 0
            } else if fields.first == "LOAD", fields.count >= 2 {
                snapshot.load1 = Double(fields[1]) ?? 0
            } else if fields.first == "UPTIME", fields.count >= 2 {
                snapshot.uptimeSeconds = Double(fields[1]) ?? 0
            } else if fields.first == "DISK", fields.count >= 4 {
                // DISK <fs> <blocks> <used> <avail> …
                snapshot.diskSizeKiB = UInt64(fields[2]) ?? 0
                snapshot.diskUsedKiB = UInt64(fields[3]) ?? 0
            }
        }
        return sawCPU && snapshot.memTotalKiB > 0 ? snapshot : nil
    }

    /// Whole-VM CPU% between two cumulative snapshots.
    static func cpuPercent(previous: GuestSnapshot, current: GuestSnapshot) -> Double {
        let total = Double(current.totalJiffies) - Double(previous.totalJiffies)
        let busy = Double(current.busyJiffies) - Double(previous.busyJiffies)
        guard total > 0, busy >= 0 else { return 0 }
        return min(100, busy / total * 100)
    }

    // MARK: - Per-container sample (raw /containers/{id}/stats dict)

    /// Cumulative counters; rates come from deltas between polls.
    struct ContainerSample {
        var cpuPercent: Double
        var memUsedBytes: UInt64
        var memLimitBytes: UInt64
        var netRxBytes: UInt64
        var netTxBytes: UInt64
        var blockReadBytes: UInt64
        var blockWriteBytes: UInt64
    }

    static func containerSample(from dict: [String: Any]) -> ContainerSample? {
        guard let stats = ContainerStats(dict: dict) else { return nil }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for interface in (dict["networks"] as? [String: [String: Any]] ?? [:]).values {
            rx += (interface["rx_bytes"] as? NSNumber)?.uint64Value ?? 0
            tx += (interface["tx_bytes"] as? NSNumber)?.uint64Value ?? 0
        }
        var read: UInt64 = 0, write: UInt64 = 0
        let blkio = (dict["blkio_stats"] as? [String: Any])?["io_service_bytes_recursive"] as? [[String: Any]] ?? []
        for entry in blkio {
            let value = (entry["value"] as? NSNumber)?.uint64Value ?? 0
            switch (entry["op"] as? String)?.lowercased() {
            case "read": read += value
            case "write": write += value
            default: break
            }
        }
        return ContainerSample(
            cpuPercent: stats.cpuPercent,
            memUsedBytes: UInt64(max(0, stats.memoryUsedBytes)),
            memLimitBytes: UInt64(max(0, stats.memoryLimitBytes)),
            netRxBytes: rx, netTxBytes: tx,
            blockReadBytes: read, blockWriteBytes: write
        )
    }

    /// bytes/s between two cumulative counters (0 when counters reset).
    static func rate(_ previous: UInt64, _ current: UInt64, seconds: Double) -> Double {
        guard seconds > 0, current >= previous else { return 0 }
        return Double(current - previous) / seconds
    }

    // MARK: - /system/df breakdown

    struct DiskBreakdown: Equatable {
        var imagesBytes: UInt64 = 0
        var imagesReclaimable: UInt64 = 0
        var containersBytes: UInt64 = 0
        var volumesBytes: UInt64 = 0
        var volumesReclaimable: UInt64 = 0
        var buildCacheBytes: UInt64 = 0
        var buildCacheReclaimable: UInt64 = 0
        var totalBytes: UInt64 {
            imagesBytes + containersBytes + volumesBytes + buildCacheBytes
        }
    }

    static func diskBreakdown(from dict: [String: Any]) -> DiskBreakdown {
        var breakdown = DiskBreakdown()
        // LayersSize counts each shared layer once — truer than summing images.
        breakdown.imagesBytes = (dict["LayersSize"] as? NSNumber)?.uint64Value ?? 0
        for image in dict["Images"] as? [[String: Any]] ?? [] where
            ((image["Containers"] as? NSNumber)?.intValue ?? 0) == 0 {
            breakdown.imagesReclaimable += (image["Size"] as? NSNumber)?.uint64Value ?? 0
        }
        for container in dict["Containers"] as? [[String: Any]] ?? [] {
            breakdown.containersBytes += (container["SizeRw"] as? NSNumber)?.uint64Value ?? 0
        }
        for volume in dict["Volumes"] as? [[String: Any]] ?? [] {
            let size = ((volume["UsageData"] as? [String: Any])?["Size"] as? NSNumber)?.uint64Value ?? 0
            breakdown.volumesBytes += size
            if ((volume["UsageData"] as? [String: Any])?["RefCount"] as? NSNumber)?.intValue == 0 {
                breakdown.volumesReclaimable += size
            }
        }
        for cache in dict["BuildCache"] as? [[String: Any]] ?? [] {
            let size = (cache["Size"] as? NSNumber)?.uint64Value ?? 0
            breakdown.buildCacheBytes += size
            if (cache["InUse"] as? Bool) != true { breakdown.buildCacheReclaimable += size }
        }
        return breakdown
    }
}
