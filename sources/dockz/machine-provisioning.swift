import Foundation

/// Template provisioning for machines: runs the template's script over SSH
/// once the machine is booted and reachable, captures the k3s join token, and
/// pulls the kubeconfig back to the host.
extension MachineManager {
    func metaURL(for name: String) -> URL {
        machinesDir.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("machine.json")
    }

    func loadMeta(name: String) -> MachineMeta {
        guard let data = try? Data(contentsOf: metaURL(for: name)),
              let meta = try? JSONDecoder().decode(MachineMeta.self, from: data) else {
            return MachineMeta()
        }
        return meta
    }

    func saveMeta(name: String, _ meta: MachineMeta) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(meta) {
            try? data.write(to: metaURL(for: name))
        }
    }

    func kubeconfigURL(for name: String) -> URL {
        machinesDir.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("kubeconfig")
    }

    /// Called from afterBoot once the machine has an IP. Waits for SSH, then
    /// applies the template if one is pending.
    func applyTemplateIfNeeded(name: String, ip: String) {
        let meta = loadMeta(name: name)
        guard !meta.provisioned, meta.template() != .none else { return }
        guard provisioningMachine == nil else { return } // one at a time
        provisioningMachine = name
        provisioningLog = "Waiting for SSH…\n"

        waitForSSH(ip: ip, attempt: 0) { [weak self] reachable in
            guard let self else { return }
            guard reachable else {
                self.finishProvisioning(name: name, success: false, message: "SSH never became reachable")
                return
            }
            self.runTemplate(name: name, ip: ip, meta: meta)
        }
    }

    private func runTemplate(name: String, ip: String, meta: MachineMeta) {
        let template = meta.template()
        var peers: [String: TemplateContext.Peer] = [:]
        for machine in machines where machine.name != name {
            let peerMeta = loadMeta(name: machine.name)
            peers[machine.name] = .init(ip: machine.ip, k3sToken: peerMeta.k3sToken,
                                        k8sJoinCommand: peerMeta.k8sJoinCommand)
        }
        let context = TemplateContext(machineIP: ip, otherMachines: peers)
        let script = template.provisioningScript(context: context)
        guard !script.isEmpty else {
            finishProvisioning(name: name, success: true, message: nil)
            return
        }

        provisioningLog += "Provisioning \(template.displayName)…\n"
        var collected = ""
        sshRunScript(ip: ip, script: script, onOutput: { [weak self] chunk in
            collected += chunk
            self?.provisioningLog += chunk
        }, onDone: { [weak self] exitCode in
            guard let self else { return }
            var updated = meta
            if template.isClusterMaster {
                if let token = MachineTemplate.extractK3sToken(from: collected) {
                    updated.k3sToken = token
                }
                if let join = MachineTemplate.extractK8sJoinCommand(from: collected) {
                    updated.k8sJoinCommand = join
                }
                self.fetchKubeconfig(name: name, ip: ip, meta: meta)
            }
            updated.provisioned = exitCode == 0
            self.saveMeta(name: name, updated)
            self.finishProvisioning(
                name: name,
                success: exitCode == 0,
                message: exitCode == 0 ? nil : "provisioning exited with code \(exitCode)"
            )
        })
    }

    private func finishProvisioning(name: String, success: Bool, message: String?) {
        DispatchQueue.main.async {
            self.provisioningLog += success ? "\n✓ done\n" : "\n✗ \(message ?? "failed")\n"
            self.provisioningMachine = nil
            if let message, !success { self.lastError = message }
            self.scan()
        }
    }

    // MARK: - SSH helpers

    private func waitForSSH(ip: String, attempt: Int, completion: @escaping (Bool) -> Void) {
        guard attempt < 30 else {
            completion(false)
            return
        }
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = self.sshBaseArgs(ip: ip) + ["-o", "ConnectTimeout=4", "true"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                DispatchQueue.main.async { completion(true) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.waitForSSH(ip: ip, attempt: attempt + 1, completion: completion)
                }
            }
        }
    }

    private func sshRunScript(ip: String, script: String, onOutput: @escaping (String) -> Void, onDone: @escaping (Int32) -> Void) {
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = self.sshBaseArgs(ip: ip) + ["/bin/sh", "-s"]
            let stdin = Pipe()
            let output = Pipe()
            process.standardInput = stdin
            process.standardOutput = output
            process.standardError = output
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { onOutput(text) }
            }
            do {
                try process.run()
                stdin.fileHandleForWriting.write(Data(script.utf8))
                try? stdin.fileHandleForWriting.close()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async { onOutput("failed to launch ssh: \(error.localizedDescription)\n") }
            }
            output.fileHandleForReading.readabilityHandler = nil
            let code = process.terminationStatus
            DispatchQueue.main.async { onDone(code) }
        }
    }

    private func fetchKubeconfig(name: String, ip: String, meta: MachineMeta) {
        // k3s writes /etc/rancher/k3s/k3s.yaml; kubeadm writes /etc/kubernetes/admin.conf.
        let remotePath = meta.engine == "k8s" ? "/etc/kubernetes/admin.conf" : "/etc/rancher/k3s/k3s.yaml"
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = self.sshBaseArgs(ip: ip) + ["cat", remotePath]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  var config = String(data: data, encoding: .utf8) else { return }
            // k3s writes server: https://127.0.0.1:6443 — point it at the VM IP.
            config = config.replacingOccurrences(of: "127.0.0.1", with: ip)
            try? config.write(to: self.kubeconfigURL(for: name), atomically: true, encoding: .utf8)
        }
    }

    private func sshBaseArgs(ip: String) -> [String] {
        [
            "-i", sshKeyPath,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "root@\(ip)",
        ]
    }
}
