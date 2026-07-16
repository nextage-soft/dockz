import Foundation

/// Cluster engine a template installs.
enum ClusterEngine: String, CaseIterable {
    case k3s
    case k8s      // upstream Kubernetes via kubeadm

    var displayName: String {
        switch self {
        case .k3s: return "k3s (lightweight)"
        case .k8s: return "Kubernetes (kubeadm)"
        }
    }
}

/// Role of a cluster node.
enum ClusterRole: String, CaseIterable {
    case master   // control-plane (k3s server / kubeadm init)
    case node     // worker (k3s agent / kubeadm join)

    var displayName: String {
        switch self {
        case .master: return "Master (control-plane)"
        case .node: return "Node (worker)"
        }
    }
}

/// Minimum machine resources a template needs. Master roles are heavier.
struct MinimumSpec {
    var cpus: Int
    var memoryGiB: Int

    static func forTemplate(_ template: MachineTemplate) -> MinimumSpec {
        switch template {
        case .none, .custom:
            return MinimumSpec(cpus: 1, memoryGiB: 1)
        case .cluster(let engine, let role, _):
            switch (engine, role) {
            case (.k3s, .master): return MinimumSpec(cpus: 2, memoryGiB: 2)
            case (.k3s, .node): return MinimumSpec(cpus: 1, memoryGiB: 1)
            case (.k8s, _): return MinimumSpec(cpus: 2, memoryGiB: 2)   // kubeadm needs 2/2 both roles
            }
        }
    }
}

/// Provisioning template applied to a machine over SSH after first boot.
enum MachineTemplate: Equatable {
    case none
    case cluster(engine: ClusterEngine, role: ClusterRole, serverName: String?)
    case custom(script: String)

    var storageKind: String {
        switch self {
        case .none: return "none"
        case .cluster(let engine, let role, _): return "\(engine.rawValue)-\(role.rawValue)"
        case .custom: return "custom"
        }
    }

    var displayName: String {
        switch self {
        case .none: return "None (plain OS)"
        case .cluster(let engine, let role, _): return "\(engine.displayName) — \(role.displayName)"
        case .custom: return "Custom script"
        }
    }

    /// True when this template pulls a kubeconfig back to the host (masters).
    var isClusterMaster: Bool {
        if case .cluster(_, .master, _) = self { return true }
        return false
    }

    func provisioningScript(context: TemplateContext) -> String {
        switch self {
        case .none:
            return ""
        case .custom(let script):
            return script
        case .cluster(let engine, let role, let serverName):
            switch engine {
            case .k3s: return k3sScript(role: role, serverName: serverName, context: context)
            case .k8s: return k8sScript(role: role, serverName: serverName, context: context)
            }
        }
    }

    // MARK: - k3s (all distros; get.k3s.io auto-detects systemd/openrc)

    private func k3sScript(role: ClusterRole, serverName: String?, context: TemplateContext) -> String {
        switch role {
        case .master:
            return """
            set -e
            echo '>>> installing k3s server'
            curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --tls-san \(context.machineIP)" sh -
            echo '>>> waiting for node Ready'
            for i in $(seq 1 60); do /usr/local/bin/kubectl get node >/dev/null 2>&1 && break; sleep 2; done
            /usr/local/bin/kubectl get nodes || true
            echo '>>> DOCKZ-K3S-TOKEN:' $(cat /var/lib/rancher/k3s/server/node-token)
            echo '>>> k3s server ready'
            """
        case .node:
            let server = serverName.flatMap { context.otherMachines[$0] }
            let url = server?.ip.map { "https://\($0):6443" } ?? ""
            let token = server?.k3sToken ?? ""
            return """
            set -e
            echo '>>> joining k3s server \(url)'
            curl -sfL https://get.k3s.io | K3S_URL="\(url)" K3S_TOKEN="\(token)" sh -
            echo '>>> k3s agent joined'
            """
        }
    }

    // MARK: - Kubernetes via kubeadm (Debian/Ubuntu only)

    private func k8sScript(role: ClusterRole, serverName: String?, context: TemplateContext) -> String {
        let common = """
        set -e
        export DEBIAN_FRONTEND=noninteractive
        echo '>>> disabling swap'
        swapoff -a || true
        sed -i '/ swap / s/^/#/' /etc/fstab || true
        echo '>>> kernel modules + sysctl'
        modprobe overlay; modprobe br_netfilter
        printf 'overlay\\nbr_netfilter\\n' > /etc/modules-load.d/k8s.conf
        printf 'net.bridge.bridge-nf-call-iptables=1\\nnet.ipv4.ip_forward=1\\nnet.bridge.bridge-nf-call-ip6tables=1\\n' > /etc/sysctl.d/k8s.conf
        sysctl --system >/dev/null
        echo '>>> installing containerd + kubeadm/kubelet/kubectl'
        apt-get update -y
        apt-get install -y apt-transport-https ca-certificates curl gpg containerd
        mkdir -p /etc/containerd
        containerd config default > /etc/containerd/config.toml
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        systemctl restart containerd; systemctl enable containerd
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
        apt-get update -y
        apt-get install -y kubelet kubeadm kubectl
        apt-mark hold kubelet kubeadm kubectl
        """
        switch role {
        case .master:
            return common + """

            echo '>>> kubeadm init'
            kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-cert-extra-sans=\(context.machineIP)
            export KUBECONFIG=/etc/kubernetes/admin.conf
            echo '>>> installing flannel CNI'
            kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
            cp /etc/kubernetes/admin.conf /etc/rancher-admin.conf 2>/dev/null || true
            echo '>>> DOCKZ-K8S-JOIN:' $(kubeadm token create --print-join-command)
            echo '>>> k8s control-plane ready'
            """
        case .node:
            let server = serverName.flatMap { context.otherMachines[$0] }
            let joinCommand = server?.k8sJoinCommand ?? ""
            return common + """

            echo '>>> joining cluster'
            \(joinCommand.isEmpty ? "echo 'no join command available — is the master ready?'; exit 1" : joinCommand)
            echo '>>> k8s node joined'
            """
        }
    }

    // MARK: - Token / join-command capture from provisioning output

    static func extractK3sToken(from output: String) -> String? {
        marker("DOCKZ-K3S-TOKEN:", in: output)
    }

    static func extractK8sJoinCommand(from output: String) -> String? {
        // The join command spans "kubeadm join ... --discovery-token-ca-cert-hash ..."
        guard let range = output.range(of: "DOCKZ-K8S-JOIN:") else { return nil }
        let after = output[range.upperBound...]
        let line = after.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func marker(_ key: String, in output: String) -> String? {
        for line in output.split(separator: "\n") where line.contains(key) {
            let parts = line.components(separatedBy: key)
            if parts.count == 2 {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}

struct TemplateContext {
    struct Peer {
        var ip: String?
        var k3sToken: String?
        var k8sJoinCommand: String?
    }
    var machineIP: String
    var otherMachines: [String: Peer]
}

/// Per-machine metadata persisted next to the disk.
struct MachineMeta: Codable {
    var templateKind: String = "none"
    var engine: String?          // "k3s" | "k8s"
    var role: String?            // "master" | "node"
    var agentServer: String?
    var customScript: String?
    var k3sToken: String?
    var k8sJoinCommand: String?
    var provisioned: Bool = false
    var distroID: String = "alpine-3.22"

    var isCloudImage: Bool {
        MachineDistro.by(id: distroID)?.isCloudImage ?? false
    }

    func template() -> MachineTemplate {
        if let engine = engine.flatMap(ClusterEngine.init),
           let role = role.flatMap(ClusterRole.init) {
            return .cluster(engine: engine, role: role, serverName: agentServer)
        }
        if templateKind == "custom" { return .custom(script: customScript ?? "") }
        return .none
    }

    static func from(_ template: MachineTemplate) -> MachineMeta {
        var meta = MachineMeta()
        meta.templateKind = template.storageKind
        switch template {
        case .cluster(let engine, let role, let server):
            meta.engine = engine.rawValue
            meta.role = role.rawValue
            meta.agentServer = server
        case .custom(let script):
            meta.customScript = script
        case .none:
            break
        }
        return meta
    }
}
