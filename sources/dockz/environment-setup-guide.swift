import Foundation

/// Step-by-step setup instructions for each environment kind, with the
/// commands pre-filled from what the user typed. Pure data so the views stay
/// thin and the generated commands are testable.
enum EnvironmentSetupGuide {
    struct Step: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        /// Shell lines to copy; `where` says which machine they run on.
        var commands: [String] = []
        var runsOn: Machine = .mac
    }

    enum Machine: String {
        case mac = "On this Mac"
        case server = "On the server"
    }

    static func steps(for kind: DockerEnvironment.Kind, address: String, port: Int?) -> [Step] {
        switch kind {
        case .ssh: return sshSteps(destination: address, port: port)
        case .tls: return tlsSteps(host: address, port: port ?? DockerEnvironment.defaultTLSPort)
        case .socket: return socketSteps()
        }
    }

    // MARK: - SSH

    static func sshSteps(destination rawDestination: String, port: Int?) -> [Step] {
        let destination = rawDestination.isEmpty ? "user@server" : rawDestination
        let portFlag = port.map { " -p \($0)" } ?? ""
        return [
            Step(title: "Let your server user run docker",
                 detail: "Docker must be installed, and the login user must use it without sudo. Log out and back in after adding the group.",
                 commands: ["sudo usermod -aG docker $USER", "docker ps"],
                 runsOn: .server),
            Step(title: "Create an SSH key (skip if you have one)",
                 detail: "Press Enter to accept the defaults. A passphrase is fine — macOS keeps it in your keychain/agent.",
                 commands: ["ssh-keygen -t ed25519"]),
            Step(title: "Install your key on the server",
                 detail: "Asks for the server password once. DockZ itself only uses key login.",
                 commands: ["ssh-copy-id\(portFlag) \(destination)"]),
            Step(title: "Check it works without a password",
                 detail: "This must print the server's Docker version with no prompt. Then press Test Connection below.",
                 commands: ["ssh\(portFlag) \(destination) docker version --format '{{.Server.Version}}'"]),
            Step(title: "Optional: bastions, other keys, odd ports",
                 detail: "Put them in ~/.ssh/config and type just the alias (here “myserver”) as Host — DockZ and the docker CLI both follow it.",
                 commands: ["""
                 cat >> ~/.ssh/config <<'EOF'
                 Host myserver
                   HostName 10.0.1.5
                   User deploy
                   Port 22
                   # ProxyJump bastion.example.com
                   # IdentityFile ~/.ssh/id_ed25519
                 EOF
                 """]),
        ]
    }

    // MARK: - TLS

    /// Subject alternative names the server certificate needs so clients can
    /// verify it by the address they connect with (IP or DNS name).
    static func serverSAN(for host: String) -> String {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var buffer = [UInt8](repeating: 0, count: 16)
        let isIP = inet_pton(AF_INET, bare, &buffer) == 1 || inet_pton(AF_INET6, bare, &buffer) == 1
        let primary = isIP ? "IP:\(bare)" : "DNS:\(bare)"
        // Loopback stays valid so the server can test itself with `docker -H`.
        return primary == "IP:127.0.0.1" ? primary : primary + ",IP:127.0.0.1"
    }

    /// Client certificates are short-lived: dockerd can't revoke a single
    /// certificate, so expiry is what bounds a leaked one. Renewing is one
    /// signing command from the editor.
    static let clientCertificateDays = 90

    static func tlsSteps(host rawHost: String, port: Int) -> [Step] {
        let host = rawHost.isEmpty ? "10.0.2.8" : rawHost
        // No client key is made here: DockZ creates it in the Mac's Secure
        // Enclave and sends only a signing request (see `signingCommands`).
        let certScript = """
        mkdir -p ~/docker-tls && cd ~/docker-tls
        openssl genrsa -out ca-key.pem 4096
        openssl req -new -x509 -days 825 -sha256 -key ca-key.pem -subj "/CN=docker-ca" -out ca.pem
        openssl genrsa -out server-key.pem 4096
        openssl req -new -key server-key.pem -subj "/CN=\(host)" -out server.csr
        printf 'subjectAltName=\(serverSAN(for: host))\\nextendedKeyUsage=serverAuth\\n' > server-ext.cnf
        openssl x509 -req -days 825 -sha256 -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out server-cert.pem -extfile server-ext.cnf
        chmod 0400 ca-key.pem server-key.pem
        sudo mkdir -p /etc/docker/tls && sudo cp ca.pem server-cert.pem server-key.pem /etc/docker/tls/
        """
        let daemonConfig = """
        sudo tee /etc/docker/daemon.json <<'EOF'
        {
          "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:\(port)"],
          "tlsverify": true,
          "tlscacert": "/etc/docker/tls/ca.pem",
          "tlscert": "/etc/docker/tls/server-cert.pem",
          "tlskey": "/etc/docker/tls/server-key.pem"
        }
        EOF
        """
        let systemdOverride = """
        sudo mkdir -p /etc/systemd/system/docker.service.d
        printf '[Service]\\nExecStart=\\nExecStart=/usr/bin/dockerd\\n' | sudo tee /etc/systemd/system/docker.service.d/dockz-tls.conf
        sudo systemctl daemon-reload && sudo systemctl restart docker
        """
        return [
            Step(title: "Prefer SSH if you can",
                 detail: "TLS opens a network port to Docker (root-equivalent access, protected only by the certificates). SSH needs no certificates and no extra port."),
            Step(title: "Create a CA and the server certificate",
                 detail: "Run on the Docker server. The server certificate is issued for \(host) — use the exact name or IP you'll type in DockZ. Whoever holds ca-key.pem can let any machine in: keep it out of reach (offline is best) between signings.",
                 commands: [certScript], runsOn: .server),
            Step(title: "Turn on TLS in dockerd",
                 detail: "If /etc/docker/daemon.json already has settings, merge these keys instead of overwriting it.",
                 commands: [daemonConfig], runsOn: .server),
            Step(title: "Let daemon.json choose the listeners",
                 detail: "Debian/Ubuntu start dockerd with “-H fd://”, which conflicts with “hosts” above and stops Docker from starting. This override removes it.",
                 commands: [systemdOverride], runsOn: .server),
            Step(title: "Open port \(port) to your Mac only",
                 detail: "Allow your Mac's IP in the server/cloud firewall. Never expose it to the whole internet.",
                 commands: ["sudo ufw allow from <your-mac-ip> to any port \(port) proto tcp"], runsOn: .server),
            Step(title: "Give DockZ the server's CA",
                 detail: "Print it, copy everything shown, then use Paste in step 1 above. ca.pem is public — no secret leaves the server.",
                 commands: ["cat ~/docker-tls/ca.pem"], runsOn: .server),
            Step(title: "Sign this Mac's key",
                 detail: "Press Create Key above (Touch ID). DockZ shows a command containing this Mac's signing request — run it on the server and paste the certificate it prints in step 3. It's valid \(clientCertificateDays) days; renew with Show Signing Request."),
            Step(title: "If this Mac is lost or compromised",
                 detail: "Docker can't revoke one certificate. Make a new CA and server certificate (step 2 again, after moving the old ~/docker-tls aside), restart Docker, and sign the Macs you still trust. Every certificate from the old CA stops working at once."),
        ]
    }

    /// What the server admin runs to sign `request` (a PEM CSR from DockZ).
    static func signingCommands(for request: String) -> String {
        """
        cd ~/docker-tls
        cat > dockz.csr <<'EOF'
        \(request.trimmingCharacters(in: .whitespacesAndNewlines))
        EOF
        printf 'extendedKeyUsage=clientAuth\\n' > dockz-ext.cnf
        openssl x509 -req -days \(clientCertificateDays) -sha256 -in dockz.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out dockz-cert.pem -extfile dockz-ext.cnf
        cat dockz-cert.pem
        """
    }

    // MARK: - Socket

    /// Where common Mac Docker engines put their sockets.
    static let knownSockets: [(name: String, path: String)] = [
        ("Docker Desktop", "~/.docker/run/docker.sock"),
        ("OrbStack", "~/.orbstack/run/docker.sock"),
        ("Colima", "~/.colima/default/docker.sock"),
        ("Rancher Desktop", "~/.rd/docker.sock"),
        ("Podman machine", "~/.local/share/containers/podman/machine/podman.sock"),
    ]

    /// Known sockets that exist right now (the engine is installed and up).
    static func detectedSockets(fileManager: FileManager = .default) -> [(name: String, path: String)] {
        knownSockets.filter { fileManager.fileExists(atPath: ($0.path as NSString).expandingTildeInPath) }
    }

    static func socketSteps() -> [Step] {
        [
            Step(title: "Start the other engine",
                 detail: "Socket environments reach another Docker engine running on this Mac. It must be running for its socket to exist."),
            Step(title: "Pick its socket",
                 detail: "Detected sockets appear above. Otherwise ask the engine where its socket is:",
                 commands: ["docker context inspect --format '{{.Endpoints.docker.Host}}'"]),
        ]
    }
}

/// Turns a failed connection's error text into a next step. Matches known
/// failure classes of ssh, TLS and sockets, not individual messages.
enum EnvironmentTroubleshooting {
    static func hint(for kind: DockerEnvironment.Kind, error: String) -> String? {
        let text = error.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        if kind == .socket {
            return has("no such file", "connection refused")
                ? "That engine isn't running (or the path is wrong). Start it, then try again."
                : nil
        }

        if has("permission denied (publickey") {
            return "The server didn't accept your key. Run step “Install your key on the server”, or load the key with: ssh-add"
        }
        if has("host key verification failed", "remote host identification has changed") {
            return "The server's identity changed since you last connected. Confirm with its admin, then remove the old entry: ssh-keygen -R <host>"
        }
        if has("could not resolve hostname", "nodename nor servname") {
            return "The host name can't be found. Check spelling, VPN, or the ~/.ssh/config alias."
        }
        if has("docker: command not found", "docker: not found", "command not found") {
            return "Docker isn't on the server's PATH for non-interactive SSH sessions. Install Docker, or make sure `ssh <host> docker version` works."
        }
        if has("permission denied while trying to connect to the docker", "docker.sock: connect: permission denied") {
            return "The server user can't use Docker. Run step “Let your server user run docker”, then log in again."
        }
        if kind == .tls {
            if has("locked", "not unlocked") {
                return "This Mac's key needs Touch ID (or your login password) before it can be used. Try again and confirm."
            }
            // The server refused this Mac's certificate.
            if has("alert_unknown_ca", "alert_bad_certificate", "certificate_required", "alert_certificate_expired",
                   "alert_decrypt_error", "alert_handshake_failure") {
                return "The server rejected this Mac's certificate — it's expired, or signed by a different CA than the server uses. Sign a fresh request (Show Signing Request) with the server's CA."
            }
            // This Mac refused the server's certificate.
            if has("certificate_verify_failed", "failedtovalidatehostname", "unable to get local issuer", "certificate") {
                return "The server's certificate didn't check out. Make sure ca.pem is the CA that signed it and that it was issued for exactly this host/IP."
            }
        }
        if has("connection refused") {
            return kind == .ssh
                ? "Nothing answers SSH on that port. Check the port and that sshd is running."
                : "Docker isn't listening on that port. Check daemon.json “hosts”, the systemd override, and the firewall."
        }
        if has("timed out", "operation timed out", "no route to host", "network is unreachable") {
            return "The server can't be reached. Check the address, VPN, and firewall rules for your Mac's IP."
        }
        return nil
    }
}
