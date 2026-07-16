import Foundation

/// `Dockz selftest-edit` — headless check of the edit-form round trip:
/// inspect JSON → formFromInspect → (user edits) → mergeForEdit → create body.
enum EditSelftest {
    static func run() -> Never {
        let fixture: [String: Any] = [
            "Name": "/postgres",
            "Config": [
                "Image": "postgres:17",
                "Env": ["POSTGRES_PASSWORD=secret", "PGDATA=/var/lib/postgresql/data"],
                "Cmd": ["postgres"],
                "Labels": ["com.example.role": "db"],
                "Hostname": "0ldc0ntainer",
                "User": "",
                "Healthcheck": ["Test": ["CMD-SHELL", "pg_isready"]],
            ] as [String: Any],
            "HostConfig": [
                "Binds": ["pgdata:/var/lib/postgresql/data"],
                "PortBindings": ["5432/tcp": [["HostIp": "", "HostPort": "5432"]]],
                "RestartPolicy": ["Name": "always", "MaximumRetryCount": 0],
                "NetworkMode": "bridge",
                "Memory": 536870912,
                "CapAdd": ["SYS_NICE"],
            ] as [String: Any],
            "Mounts": [["Type": "volume", "Name": "pgdata", "Destination": "/var/lib/postgresql/data", "RW": true]],
        ]

        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        var form = ContainerConfigBuilder.formFromInspect(fixture)
        expect(form.image == "postgres:17", "form.image")
        expect(form.name == "postgres", "form.name strips slash")
        expect(form.envText.contains("POSTGRES_PASSWORD=secret"), "form.env prefill")
        expect(form.portsText == "5432:5432", "form.ports prefill")
        expect(form.volumesText == "pgdata:/var/lib/postgresql/data", "form.volumes prefill")
        expect(form.restartPolicy == "always", "form.restartPolicy")
        expect(form.network.isEmpty, "bridge maps to default")
        expect(form.memoryMiB == "512", "form.memory MiB")
        expect(form.labelsText == "com.example.role=db", "form.labels prefill")

        // Simulate user edits: change env, add a port, drop the memory limit.
        form.envText = "POSTGRES_PASSWORD=newpass\nPGDATA=/var/lib/postgresql/data"
        form.portsText = "5432:5432\n15432:5432"
        form.memoryMiB = ""

        let merged = ContainerConfigBuilder.mergeForEdit(base: fixture, form: form)
        let host = merged["HostConfig"] as? [String: Any] ?? [:]
        expect((merged["Env"] as? [String])?.contains("POSTGRES_PASSWORD=newpass") == true, "merged env updated")
        expect(merged["Hostname"] == nil, "stale hostname dropped")
        expect((merged["Config"] as? [String: Any]) == nil, "flat body, no nested Config")
        expect((merged["Healthcheck"] as? [String: Any]) != nil, "healthcheck preserved")
        expect((host["CapAdd"] as? [String]) == ["SYS_NICE"], "CapAdd preserved")
        expect((host["Memory"] as? Int) == 0, "memory limit cleared")
        let bindings = host["PortBindings"] as? [String: Any] ?? [:]
        expect(bindings.count == 1 && (bindings["5432/tcp"] as? [[String: Any]])?.count == 2,
               "two host ports bound to 5432/tcp")
        expect((host["Binds"] as? [String]) == ["pgdata:/var/lib/postgresql/data"], "binds preserved")
        expect(merged["Image"] as? String == "postgres:17", "image set")

        if failures.isEmpty {
            print("EDIT SELFTEST OK")
            exit(0)
        }
        print("EDIT SELFTEST FAILED: \(failures.joined(separator: ", "))")
        exit(1)
    }
}
