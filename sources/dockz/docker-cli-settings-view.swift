import SwiftUI

/// Settings section for the `docker` command line tool. DockZ's own dashboard
/// talks to the engine over vsock and needs no CLI, but compose stacks and
/// `docker exec` shells shell out to one — so offer a one-click install of the
/// official static binaries when the Mac has none.
struct DockerCLISettingsSection: View {
    @ObservedObject var store: DashboardStore
    @State private var installing = false
    @State private var status = ""
    @State private var refresh = 0

    private var resolved: DockerCLI.Resolved? {
        _ = refresh
        return DockerCLI.resolve()
    }

    var body: some View {
        Section {
            if let resolved {
                LabeledContent("Status") {
                    Label(isManaged(resolved) ? "Installed by DockZ" : "Using your own install",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                LabeledContent("Path") {
                    Text(resolved.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                if isManaged(resolved) {
                    LabeledContent("Version", value: "docker \(DockerCLIInstaller.dockerPin.version) · compose \(DockerCLIInstaller.composePin.version)")
                    if shellInstalled {
                        LabeledContent("Terminal") {
                            Label("Set up in \(rcFileName)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } else {
                        HStack {
                            Text("Make `docker` work in your own Terminal:")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Set Up Terminal") { setUpShell() }
                                .controlSize(.small)
                            Button("Copy instead") { copyShellSetup() }
                                .controlSize(.small)
                        }
                    }
                    HStack {
                        Spacer()
                        if shellInstalled {
                            Button("Undo Terminal setup") {
                                try? ShellIntegrationInstaller.uninstall()
                                status = "Removed from \(rcFileName)."
                                refresh += 1
                            }
                            .controlSize(.small)
                        }
                        Button("Remove", role: .destructive) {
                            DockerCLIInstaller.uninstall()
                            try? ShellIntegrationInstaller.uninstall()
                            refresh += 1
                        }
                        .controlSize(.small)
                    }
                }
            } else if installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status.isEmpty ? "Starting…" : status)
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Label("Not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("The dashboard works without it, but compose stacks and container shells need a `docker` binary. DockZ can download the official static build and set up your terminal — no Homebrew, no admin password.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install Docker CLI (≈\(DockerCLIInstaller.approximateDownloadMB) MB)") { install() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
            if !status.isEmpty && !installing {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Docker CLI")
        } footer: {
            Text("Downloaded from docker.com and github.com/docker/compose, then checksum-verified before use.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func isManaged(_ resolved: DockerCLI.Resolved) -> Bool {
        resolved.configDirectory != nil
    }

    private var shellInstalled: Bool {
        _ = refresh
        return ShellIntegrationInstaller.isInstalled()
    }

    private var rcFileName: String {
        "~/" + ShellIntegrationInstaller.rcFileURL().lastPathComponent
    }

    private func setUpShell() {
        do {
            try ShellIntegrationInstaller.install()
            status = "Done — open a new terminal and `docker ps` just works."
        } catch {
            status = error.localizedDescription
        }
        refresh += 1
    }

    private func install() {
        installing = true
        status = ""
        DockerCLIInstaller.install(progress: { status = $0 }) { result in
            installing = false
            switch result {
            case .success:
                // Finish the job: wire the terminal too, so `docker` works in a
                // new shell without a second click. The block steps aside by
                // itself if a system docker ever appears.
                try? ShellIntegrationInstaller.install()
                status = "Installed — open a new terminal and `docker ps` just works."
                refresh += 1
                // The `dockz` context can now be created with the new CLI.
                DockerContextInstaller.ensureContext(socketPath: DockzPaths().dockerSocket.path)
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }

    /// Both lines are needed: PATH finds the binary, DOCKER_CONFIG is where its
    /// compose plugin and the `dockz` context live.
    private func copyShellSetup() {
        let paths = DockzPaths()
        let lines = """
        export PATH="\(paths.managedCLIDirectory.path):$PATH"
        export DOCKER_CONFIG="\(paths.managedDockerConfig.path)"
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines, forType: .string)
        status = "Copied — paste into ~/.zshrc, then: docker context use dockz"
    }
}
