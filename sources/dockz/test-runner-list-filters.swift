import Foundation

/// List filtering shared by every page, and the container facts it relies on
/// (status texts are Docker's own wording).
extension TestRunner {
    static func listFilters() {
        func container(_ name: String, state: String, status: String, image: String = "redis:7",
                       project: String? = nil, created: Int = 0, volumes: [String] = [],
                       imageID: String = "sha256:aaa") -> ContainerSummary {
            var labels: [String: String] = [:]
            if let project { labels["com.docker.compose.project"] = project }
            return ContainerSummary(dict: [
                "Id": name + "-id", "Names": ["/" + name], "Image": image, "ImageID": imageID,
                "State": state, "Status": status, "Labels": labels, "Created": created,
                "Mounts": volumes.map { ["Type": "volume", "Name": $0] } + [["Type": "bind", "Source": "/x"]],
            ])!
        }

        let api = container("api", state: "running", status: "Up 4 minutes (healthy)", project: "shop", created: 30)
        let worker = container("worker", state: "running", status: "Up 2 hours (unhealthy)", project: "shop", created: 20)
        let crashed = container("migrate", state: "exited", status: "Exited (1) 8 days ago", created: 10)
        let stopped = container("cache", state: "exited", status: "Exited (137) 2 days ago", volumes: ["cache-data"])
        let clean = container("job", state: "exited", status: "Exited (0) 1 hour ago")
        let untagged = container("old", state: "exited", status: "Exited (143) 9 days ago",
                                 image: "sha256:31f366eda1fa60b413d913ebe5ed51224e7df924e9f497daaf24a6fa5b65d440")
        let all = [crashed, stopped, api, clean, worker, untagged]

        // Facts derived from Docker's status text.
        expectEqual(api.health, .healthy, "container: healthy parsed")
        expectEqual(api.statusText, "Up 4 minutes", "container: health suffix removed from status")
        expectEqual(worker.health, .unhealthy, "container: unhealthy parsed")
        expectEqual(container("x", state: "running", status: "Up 3 seconds (health: starting)").health, .starting,
                    "container: health starting parsed")
        expectEqual(crashed.exitCode, 1, "container: exit code parsed")
        expect(crashed.isCrashed && crashed.displayState == "crashed", "container: non-zero exit is crashed")
        expect(!stopped.isCrashed && !clean.isCrashed && !untagged.isCrashed,
               "container: exit 0 / SIGKILL / SIGTERM count as stopped")
        expect(container("d", state: "dead", status: "Dead").isCrashed, "container: dead is crashed")
        expectEqual(untagged.imageLabel, "untagged 31f366eda1fa", "container: untagged image shortened")
        expectEqual(api.imageLabel, "redis:7", "container: tagged image unchanged")
        expectEqual(stopped.volumeNames, ["cache-data"], "container: only volume mounts listed")

        // Scopes, counts, sort, search.
        let filter = ListFilters.containers
        let counts = Dictionary(uniqueKeysWithValues: filter.options(for: all, query: "").map { ($0.id, $0.count) })
        expectEqual(counts, ["all": 6, "running": 2, "stopped": 3, "problems": 2], "filter: container scope counts")
        expectEqual(filter.apply(all, scope: "status", query: "", sort: "status").map(\.name),
                    ["api", "worker", "migrate", "cache", "job", "old"],
                    "filter: unknown scope falls back to All; status sort = running, problems, crashed, stopped")
        expectEqual(filter.apply(all, scope: "problems", query: "", sort: "name").map(\.name), ["migrate", "worker"],
                    "filter: problems = crashed + unhealthy")
        expectEqual(filter.apply(all, scope: "all", query: "", sort: "newest").prefix(3).map(\.name),
                    ["api", "worker", "migrate"], "filter: newest first")
        expectEqual(filter.apply(all, scope: "all", query: "shop WORK", sort: "name").map(\.name), ["worker"],
                    "filter: every term must match (stack + name, any case)")
        expectEqual(filter.options(for: all, query: "shop").first?.count, 2, "filter: chip counts follow the search")

        // Usage-based scopes.
        let images = [
            ImageSummary(dict: ["Id": "sha256:aaa", "RepoTags": ["redis:7"], "Size": 30, "Created": 2])!,
            ImageSummary(dict: ["Id": "sha256:bbb", "RepoTags": ["nginx:1"], "Size": 90, "Created": 1])!,
            ImageSummary(dict: ["Id": "sha256:ccc", "RepoTags": ["<none>:<none>"], "Size": 10, "Created": 3])!,
        ]
        let imageFilter = ListFilters.images(usedImageIDs: Set(all.map(\.imageID)))
        expectEqual(imageFilter.apply(images, scope: "used", query: "", sort: "name").map(\.repoTag), ["redis:7"],
                    "filter: images in use")
        expectEqual(imageFilter.apply(images, scope: "unused", query: "", sort: "name").map(\.repoTag), ["nginx:1"],
                    "filter: unused excludes dangling")
        expectEqual(imageFilter.apply(images, scope: "dangling", query: "", sort: "name").count, 1, "filter: dangling")
        expectEqual(imageFilter.apply(images, scope: "all", query: "", sort: "size").first?.repoTag, "nginx:1",
                    "filter: largest first")

        let volumes = [VolumeSummary(dict: ["Name": "cache-data"])!, VolumeSummary(dict: ["Name": "orphan"])!]
        let volumeFilter = ListFilters.volumes(usedVolumeNames: Set(all.flatMap(\.volumeNames)))
        expectEqual(volumeFilter.apply(volumes, scope: "unused", query: "", sort: "name").map(\.name), ["orphan"],
                    "filter: unused volumes")

        let environments = [
            DockerEnvironment(name: "prod", kind: .ssh, address: "deploy@10.0.0.5", port: nil),
            DockerEnvironment(name: "Édge", kind: .tls, address: "10.0.0.9", port: 2376),
        ]
        expectEqual(ListFilters.environments.apply(environments, scope: "tls", query: "", sort: "name").map(\.name),
                    ["Édge"], "filter: environments by kind")
        expectEqual(ListFilters.environments.apply(environments, scope: "all", query: "edge", sort: "name").count, 1,
                    "filter: search ignores accents")
    }
}
