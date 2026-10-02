import Foundation

/// The scopes, search fields and sort orders of each list page, side by side
/// so the pages stay consistent. Usage-based scopes ("In use") take the set of
/// ids currently referenced by containers.
enum ListFilters {
    // MARK: Containers

    static let containers = ListFilter<ContainerSummary>(
        scopes: [
            ListFilter.allScope,
            .init(id: "running", title: "Running") { $0.isRunning },
            .init(id: "stopped", title: "Stopped") { !$0.isRunning && !$0.isCrashed },
            .init(id: "problems", title: "Problems") { $0.hasProblem },
        ],
        sorts: [
            .init(id: "status", title: "Status") { lhs, rhs in
                let (left, right) = (containerRank(lhs), containerRank(rhs))
                return left != right ? left < right : namesAscending(lhs.name, rhs.name)
            },
            .init(id: "name", title: "Name") { namesAscending($0.name, $1.name) },
            .init(id: "newest", title: "Newest") { $0.created > $1.created },
        ],
        searchKeys: { [$0.name, $0.image, $0.composeProject ?? "", $0.portsLabel, $0.shortID] }
    )

    /// Running first, then what needs attention, then the rest.
    private static func containerRank(_ container: ContainerSummary) -> Int {
        if container.isRunning { return container.health == .unhealthy ? 1 : 0 }
        if container.state == "restarting" || container.state == "paused" { return 1 }
        return container.isCrashed ? 2 : 3
    }

    // MARK: Images

    static func images(usedImageIDs: Set<String>) -> ListFilter<ImageSummary> {
        ListFilter(
            scopes: [
                ListFilter.allScope,
                .init(id: "used", title: "In use") { usedImageIDs.contains($0.id) },
                .init(id: "unused", title: "Unused") { !usedImageIDs.contains($0.id) && !$0.isDangling },
                .init(id: "dangling", title: "Dangling") { $0.isDangling },
            ],
            sorts: [
                .init(id: "name", title: "Name") { namesAscending($0.repoTag, $1.repoTag) },
                .init(id: "size", title: "Largest") { $0.sizeBytes > $1.sizeBytes },
                .init(id: "newest", title: "Newest") { $0.created > $1.created },
            ],
            searchKeys: { [$0.repoTag, $0.shortID] }
        )
    }

    // MARK: Volumes

    static func volumes(usedVolumeNames: Set<String>) -> ListFilter<VolumeSummary> {
        ListFilter(
            scopes: [
                ListFilter.allScope,
                .init(id: "used", title: "In use") { usedVolumeNames.contains($0.name) },
                .init(id: "unused", title: "Unused") { !usedVolumeNames.contains($0.name) },
            ],
            sorts: [.init(id: "name", title: "Name") { namesAscending($0.name, $1.name) }],
            searchKeys: { [$0.name, $0.driver] }
        )
    }

    // MARK: Networks

    static let networks = ListFilter<NetworkSummary>(
        scopes: [
            ListFilter.allScope,
            .init(id: "custom", title: "Custom") { !$0.isBuiltin },
            .init(id: "builtin", title: "Built-in") { $0.isBuiltin },
        ],
        sorts: [.init(id: "name", title: "Name") { namesAscending($0.name, $1.name) }],
        searchKeys: { [$0.name, $0.driver, $0.shortID] }
    )

    // MARK: Stacks

    static let stacks = ListFilter<StackRow>(
        scopes: [
            ListFilter.allScope,
            .init(id: "running", title: "Running") { $0.totalCount > 0 && $0.runningCount == $0.totalCount },
            .init(id: "partial", title: "Partial") { $0.runningCount > 0 && $0.runningCount < $0.totalCount },
            .init(id: "stopped", title: "Stopped") { $0.runningCount == 0 },
        ],
        sorts: [.init(id: "name", title: "Name") { namesAscending($0.name, $1.name) }],
        searchKeys: { [$0.name, $0.composePath ?? ""] }
    )

    // MARK: Machines

    static let machines = ListFilter<MachineManager.Machine>(
        scopes: [
            ListFilter.allScope,
            .init(id: "running", title: "Running") { $0.state == .running },
            .init(id: "stopped", title: "Stopped") { $0.state != .running },
        ],
        sorts: [.init(id: "name", title: "Name") { namesAscending($0.name, $1.name) }],
        searchKeys: { [$0.name, $0.ip ?? ""] }
    )

    // MARK: Registries

    static let registries = ListFilter<RegistryEntry>(
        scopes: [ListFilter.allScope],
        sorts: [.init(id: "name", title: "Name") { namesAscending($0.name, $1.name) }],
        searchKeys: { [$0.name, $0.server, $0.username] }
    )

    // MARK: Environments

    static let environments = ListFilter<DockerEnvironment>(
        scopes: [ListFilter.allScope] + DockerEnvironment.Kind.allCases.map { kind in
            .init(id: kind.rawValue, title: kind.label) { $0.kind == kind }
        },
        sorts: [.init(id: "name", title: "Name") { namesAscending($0.name, $1.name) }],
        searchKeys: { [$0.name, $0.address] }
    )
}
