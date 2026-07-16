import Foundation

/// A guest distribution available as a machine base image. Every option is
/// ARM64 (Apple Silicon Virtualization is native-arch only) — there is no
/// x86 choice by design.
///
/// Provisioning style:
///  - `.netboot`  → built from scratch via the Alpine netboot flow (has the
///    DockZ vsock agent, so IP/shell work over vsock; templates verified).
///  - `.cloudImage` → a downloaded cloud image booted with a cloud-init seed
///    (no vsock agent; IP comes from the vmnet DHCP lease). Preset templates
///    are disabled here so nothing half-works — only None / Custom script.
struct MachineDistro: Identifiable, Equatable {
    enum Provisioning: Equatable {
        case netboot
        case cloudImage(rawURL: String, isCompressed: Bool, isQcow2: Bool)
    }

    let id: String            // "alpine-3.22", "debian-13", "ubuntu-24.04"
    let family: String        // "alpine" | "debian" | "ubuntu"
    let version: String
    let displayName: String
    let provisioning: Provisioning
    /// Cluster engines whose templates are offered for this distro:
    ///  - k3s: works everywhere (get.k3s.io auto-detects systemd/openrc).
    ///  - k8s (kubeadm): Debian/Ubuntu only (Alpine's musl breaks kubeadm).
    let supportedEngines: [ClusterEngine]

    var arch: String { "arm64" }

    var templatesSupported: Bool { !supportedEngines.isEmpty }

    var isCloudImage: Bool {
        if case .cloudImage = provisioning { return true }
        return false
    }

    static let catalog: [MachineDistro] = [
        MachineDistro(
            id: "alpine-3.22", family: "alpine", version: "3.22",
            displayName: "Alpine 3.22 (recommended)",
            provisioning: .netboot, supportedEngines: [.k3s]
        ),
        MachineDistro(
            id: "alpine-edge", family: "alpine", version: "edge",
            displayName: "Alpine edge",
            provisioning: .netboot, supportedEngines: [.k3s]
        ),
        MachineDistro(
            id: "debian-13", family: "debian", version: "13",
            displayName: "Debian 13 (trixie)",
            provisioning: .cloudImage(
                rawURL: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.raw",
                isCompressed: false, isQcow2: false
            ),
            supportedEngines: [.k3s, .k8s]
        ),
        MachineDistro(
            id: "debian-12", family: "debian", version: "12",
            displayName: "Debian 12 (bookworm)",
            provisioning: .cloudImage(
                rawURL: "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.raw",
                isCompressed: false, isQcow2: false
            ),
            supportedEngines: [.k3s, .k8s]
        ),
        MachineDistro(
            id: "ubuntu-24.04", family: "ubuntu", version: "24.04",
            displayName: "Ubuntu 24.04 LTS",
            provisioning: .cloudImage(
                rawURL: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img",
                isCompressed: false, isQcow2: true
            ),
            supportedEngines: [.k3s, .k8s]
        ),
    ]

    static func by(id: String) -> MachineDistro? {
        catalog.first { $0.id == id }
    }
}

/// A built/available base image on disk (~/.dockz/machines/bases/<id>.img).
struct MachineBase: Identifiable, Codable, Equatable {
    var id: String            // distro id
    var displayName: String
    var family: String
    var arch: String
    var builtAt: String       // ISO date (informational)

    var imageFileName: String { "\(id).img" }
}
