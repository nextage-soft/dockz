<p align="center">
  <img src="public/social-preview.png" alt="DockZ — Docker &amp; Linux VMs on Apple Silicon, natively" width="880">
</p>

<p align="center">A menu bar app that boots the real <code>dockerd</code> in a tiny Alpine VM —<br>
plus a Docker Desktop–style dashboard and Multipass-style Linux machines.</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B%20·%20Apple%20Silicon-black" alt="platform">
  <img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="license">
  <img src="https://img.shields.io/badge/Swift%20dependencies-Apple%20swift--nio--ssl%20only-success" alt="dependencies">
  <img src="https://img.shields.io/badge/app%20size-~8%20MB-orange" alt="size">
</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#why-dockz">Why DockZ</a> ·
  <a href="#install--build">Install</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#architecture">Architecture</a>
</p>

Built entirely on Apple's **Virtualization.framework** — no external runtimes,
one Swift dependency (Apple's own swift-nio-ssl, pinned exactly). The engine is exposed to the host
as a normal Docker context: `docker`, `docker compose`, and buildx just work.

<p align="center">
  <img src="public/architecture.svg" alt="DockZ architecture" width="880">
</p>

---

## Screenshots

|                       Containers                       |                    Images                    |
| :---------------------------------------------------: | :------------------------------------------: |
| ![Containers](public/dashboard-containers.png)        | ![Images](public/dashboard-images.png)       |
|                    **Machines**                       |              **Settings / About**            |
| ![Machines](public/dashboard-machines.png)            | ![Settings](public/dashboard-settings.png)   |

---

## Features

| | |
| --- | --- |
| 🐳&nbsp;**Real Docker engine** | Genuine `dockerd` in Alpine Linux, exposed as the `dockz` context — `docker`, `docker compose`, buildx all work. |
| 🖥️&nbsp;**Management dashboard** | Docker Desktop / Portainer style: containers, images, volumes, networks, registries, compose **stacks** — create/edit forms, live logs, stats, inspect. Every list has scope chips, search and sort; containers are grouped by stack, with crashes and unhealthy health checks flagged (⌘F / ⌘R / ⌘N). |
| 📊&nbsp;**Monitor** | Live CPU, memory, network and disk I/O per container, VM vitals, a storage breakdown, and cleanup of unused images, volumes and build cache. |
| 🌐&nbsp;**Multiple environments** | Manage other Docker engines too — remote hosts over **SSH** or **mutual TLS**, or another engine's socket on this Mac — and switch every tab between them from the sidebar (⌘1…⌘9). Management only: nothing is joined or shared. |
| 🛟&nbsp;**Self-healing VM** | If dockerd stops answering or the guest kernel fails, DockZ restarts the VM itself (crash-loop limited) and keeps the console logs of the last boots. |
| 📦&nbsp;**Linux machines** | Multipass-style VMs (Alpine / Debian / Ubuntu, ARM64) over SSH, with one-click **k3s / k8s** master/node cluster templates. |
| 🚀&nbsp;**One-window onboarding** | First launch builds the guest image in a throwaway netboot VM and installs the CLI in parallel — when it closes, `docker ps` works. |
| 🔌&nbsp;**Auto port forwarding** | Published TCP + UDP ports mirrored on `localhost` by watching the Docker events API. |
| 📸&nbsp;**VM snapshots** | Instant APFS copy-on-write snapshots of the VM disk, with rollback. |
| 🔄&nbsp;**Rosetta** | Run `linux/amd64` images on Apple Silicon. |
| ⚙️&nbsp;**Configurable** | CPUs, memory, disk limit, `$HOME` virtiofs share, relocatable data folder (external SSD friendly). |
| 🧰&nbsp;**Docker CLI on demand** | No Homebrew: official static `docker` + compose fetched checksum-verified, terminal wired via a removable `~/.zshrc` block that steps aside for your own install. |
| 🪶&nbsp;**Minimal dependencies** | Apple frameworks, in-repo code, and Apple's open-source swift-nio-ssl (exact pins) for Secure Enclave–backed TLS keys; builds with just the Command Line Tools. |

## Why DockZ?

**One 8 MB native app replaces the whole stack**: Docker engine + Docker
Desktop–style dashboard + Multipass-style Linux VMs + k3s/k8s playgrounds — free,
Apache-2.0, no accounts, no telemetry, no Electron.

What makes it different from the usual suspects:

- **Genuinely tiny and native.** The app bundle is ~8 MB (a 3.5 MB download) of Swift/SwiftUI on
  Apple's Virtualization.framework. No Electron shell, no bundled node/qemu, no
  background updater. The 64 GB VM disk is APFS-sparse — a fresh engine really
  occupies ~1.3 GB.
- **Self-bootstrapping on an empty Mac.** The classic chicken-and-egg ("you need
  Docker to build the Docker VM image") is gone: first launch builds the guest
  image inside a throwaway Alpine netboot VM and fetches the official `docker` +
  compose CLIs in parallel, checksum-verified. No Homebrew, no admin password,
  no curl-pipe-bash.
- **Real `dockerd`, not a reimplementation.** 100 % engine compatibility —
  buildx, compose, registries, everything — because it *is* upstream Docker
  running in Alpine. The socket is bridged over vsock; published ports appear on
  `localhost` automatically (TCP + UDP).
- **Two products in one.** Containers *and* full Linux machines (Alpine, Debian,
  Ubuntu) with SSH, cloud-init, APFS instant clones, and one-click k3s/k8s
  master/node templates — the Docker Desktop *and* the Multipass use case,
  sharing one NAT network so multi-node clusters just work.
- **Ops niceties others gate or skip**: APFS copy-on-write VM snapshots with
  rollback, a relocatable data folder (move everything to an external SSD from
  Settings), Rosetta for `linux/amd64` images, private-registry credentials in
  the Keychain, graceful VM shutdown, and a plain-text `host.log` when you want
  to know exactly what the VM lifecycle did.
- **Auditable by one person in one sitting.** One external Swift dependency —
  Apple's swift-nio / swift-nio-ssl, pinned exactly (`Package.resolved`) and
  used only so TLS environments can keep their key in the Secure Enclave.
  Everything else is Apple frameworks and the code in this repo. It builds
  with just the Command Line Tools (the first build fetches the packages).

### Comparison <sub>(macOS · Apple Silicon · mid-2026)</sub>

|                            |     **DockZ**      | Docker Desktop  |    OrbStack     |  Colima (Lima)  |    Multipass    |
| -------------------------- | :----------------: | :-------------: | :-------------: | :-------------: | :-------------: |
| 💵 License / price         | **Apache 2.0, free** | 💰 paid ≥ 250 staff | 💰 closed, paid commercial | MIT, free | free (Canonical) |
| 💾 App on disk             |     **~8 MB**      |    ~1.5 GB+     |   100s of MB    | CLI + brew deps |     ~350 MB     |
| 🎨 UI                      |  native SwiftUI    |    Electron     |     native      |    CLI only     |   minimal GUI   |
| 🐳 Docker engine           |  real `dockerd`    | real `dockerd`  | own stack       | real `dockerd`  |        —        |
| 🖥️ Dashboard (containers/stacks) |      ✅      |       ✅        |       ✅        |       ❌        |        —        |
| 📦 General Linux VMs       | ✅ + cloud-init    |       ❌        |       ✅        |    via lima     |       ✅        |
| ☸️ k8s out of the box      | ✅ multi-node k3s/k8s | single-node  |    ✅ (k8s)     |     manual      |       ❌        |
| 🔧 Install prerequisites   |     **none**       |  admin helper   |      none       |    Homebrew     |  installer pkg  |
| 📸 VM snapshots + rollback | ✅ APFS CoW        |       ❌        |       ❌        |       ❌        |       ✅        |
| 🔓 Open source             |   ✅ fully         |    partially    |       ❌        |       ✅        |       ✅        |

*Honest caveats*: DockZ is Apple Silicon + macOS 15+ only, young, not yet
notarized, and tuned for the common paths rather than every edge case. If you
need x86 Macs, Windows/Linux parity, or a vendor SLA, the incumbents above are
the safer pick — DockZ's lane is "everything a Mac developer needs, minus the
bloat and the license worries."

## Requirements

- macOS **15 (Sequoia) or later**
- **Apple Silicon** (M1 or newer)
- Command Line Tools or Xcode (to build from source)

**No Homebrew, no Docker Desktop, no admin password.** The dashboard talks to the
engine directly over vsock, so it needs no `docker` binary at all. Compose stacks
and container shells do — if the Mac has none, DockZ downloads the official static
`docker` CLI + compose plugin (≈48 MB) into its own data folder, verifying both
against pinned SHA-256 digests, makes `dockz` the default context, and adds a
conditional block to your shell rc so `docker ps` works in a new terminal. This
happens automatically during first-run setup (or later from
**Settings → Docker CLI**). An existing `docker` install is always preferred and
never touched.

## Install / Build

**Download:** grab `DockZ-<version>.dmg` from
[Releases](https://github.com/nextage-soft/dockz/releases), open it and drag
DockZ to Applications. Each release lists the DMG's SHA-256. Builds that are not
notarized are blocked on first launch — allow DockZ once in **System Settings →
Privacy & Security → Open Anyway**. To sign DockZ with your own certificate, or
to publish signed + notarized releases, see
[docs/deployment-guide.md](docs/deployment-guide.md).

**Build from source:** no full Xcode required — DockZ builds with Swift Package
Manager and a bundling script.

```bash
# Build + sign the host app  →  build/DockZ.app
scripts/build-and-bundle-app.sh
open build/DockZ.app

# Optional: pack it as build/DockZ-<version>.dmg
scripts/make-dmg.sh
```

**Publishing a release:** push a tag such as `v0.2.0`. The *Release* workflow
tests, builds, packs the DMG (signed + notarized when the secrets listed at the
top of `.github/workflows/release.yml` exist) and attaches it to a GitHub
Release. Running the workflow manually builds a DMG artifact without releasing.

Copy `build/DockZ.app` into `/Applications` to install. On first launch DockZ
offers to build the guest disk image itself (a throwaway Alpine netboot VM
provisions it over the serial console — no Docker needed anywhere) and installs
the docker CLI in parallel if the Mac has none. Headless alternatives:

```bash
# Standalone image build (same path the setup window uses):
build/DockZ.app/Contents/MacOS/DockZ build-image
# Or, with any working Docker daemon already available:
guest/build-guest-image.sh            # installs <data folder>/disk.img
# CLI + compose + shell integration without the GUI:
build/DockZ.app/Contents/MacOS/DockZ install-docker-cli
build/DockZ.app/Contents/MacOS/DockZ setup-shell        # --remove to undo
```

### Code signing (do it yourself, no paid account)

Virtualization.framework refuses to start a VM unless the app is signed with
the `com.apple.security.virtualization` entitlement
([scripts/dockz.entitlements](scripts/dockz.entitlements)). The build script
signs automatically, picking the first identity that exists:

1. `$SIGN_IDENTITY` if you export it,
2. else the first **Apple Development** certificate on the machine,
3. else an **ad-hoc** signature (`-`).

All three run the VM fine. The difference: an Apple Development certificate
gives the app a stable identity across rebuilds (macOS remembers permission
grants like Local Network), while ad-hoc is anonymous — harmless, but macOS
treats every rebuild as a brand-new app. You can create an Apple Development
certificate for free (no paid membership): Xcode → Settings → Accounts → add
your Apple ID → Manage Certificates → **+** → Apple Development.

```bash
# See what's available, then pin one explicitly if you like:
security find-identity -v -p codesigning
SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/build-and-bundle-app.sh
```

**Re-signing a downloaded DockZ.app** (e.g. from a release) with your own
signature — this both satisfies the entitlement and clears Gatekeeper's
"unidentified developer" complaint:

```bash
xattr -dr com.apple.quarantine DockZ.app
codesign --force --deep --options runtime \
  --entitlements scripts/dockz.entitlements \
  --sign - DockZ.app                      # "-" = ad-hoc; or your identity
```

Verify the entitlement took:

```bash
codesign -d --entitlements - /Applications/DockZ.app   # must list …virtualization
```

## Usage

```bash
docker run --rm hello-world
docker run --rm -p 8080:80 nginx    # reachable at http://localhost:8080
```

When DockZ installed the CLI, `dockz` is already the default context. With your
own docker install, switch once: `docker context use dockz` (or per-command:
`docker --context dockz …`).

Open the dashboard from the menu bar icon (**Open Dashboard…**, ⌘D) to manage
containers, images, volumes, networks, registries, stacks, and machines, and to
adjust VM resources, snapshots, and the data folder in **Settings**.

## Architecture

- **Host app (Swift, menu bar)** — `sources/dockz/`
  - VZ VM: EFI boot → virtio-blk disk, NAT network, virtiofs share of `$HOME` at
    the same path (fast bind mounts), vsock, Rosetta directory share, memory
    balloon + entropy, serial console → `console.log`.
  - `docker.sock` — each client connection is bridged over vsock port 2375 to
    `dockerd`'s unix socket in the guest.
  - Port forwarding — subscribes to the Docker `/events` API, lists published
    TCP/UDP ports, and mirrors them on `localhost`, relaying to the guest IP.
  - Machines — cloud-init (NoCloud) seed ISOs for cloud images; APFS clone for
    instant creation; DHCP-lease parsing for machine IPs.
  - First-run bootstrap — a throwaway Alpine **netboot builder VM**, driven over
    its serial console by a tiny expect engine (`serial-expect.swift`),
    partitions and provisions `disk.img` from scratch; the provision script
    emits `DOCKZ-STEP` markers that drive the setup window's progress bar. In
    parallel, the CLI installer fetches `docker` + compose (SHA-256 pinned) and
    wires the user's shell rc.
  - Diagnostics — every VM lifecycle event (state changes, poweroff path,
    forced stops) is appended to `host.log` beside the guest's `console.log`.
- **Guest (Alpine)** — `guest/`
  - `linux-virt` kernel, grub arm64-efi (standalone, `--removable`), OpenRC,
    `dockerd` + compose plugin.
  - Agents are just `socat`: vsock 2375 → `/var/run/docker.sock`, 2376 → report
    `eth0` IP, 2377 → graceful poweroff, 2378 → debug shell.
  - First boot grows the root partition to fill the (sparse) disk.
  - Rosetta binfmt registration when the host shares the `rosetta` tag.

### Environments (other Docker engines)

The sidebar's environment switcher points every tab — Monitor, Containers,
Stacks, Images, Volumes, Networks — at another engine. DockZ always opens on
**Local**; a remote environment gets an orange header bar and destructive
confirmations name the host. Machines stay Local-only, and Settings always
configure this Mac's VM.

| Kind | What you enter | How DockZ connects |
| --- | --- | --- |
| **SSH** | `user@host`, or a `~/.ssh/config` alias | `/usr/bin/ssh … docker system dial-stdio`, same as `docker -H ssh://`. Uses your keys, ssh-agent and ssh config (no passwords stored, key auth only). The remote user must be able to run `docker`. |
| **TLS** | host, port (2376), the server's `ca.pem`, then a certificate for this Mac's key | Mutual TLS (swift-nio-ssl) to a `dockerd --tlsverify` engine; only that CA is trusted and the server name/IP is checked. |
| **Socket** | a unix socket path | Another engine on this Mac (Colima, OrbStack, Docker Desktop). |

The Add Environment sheet carries a step-by-step setup guide for each kind
(also printable with `DockZ env-guide <ssh|tls|socket> <host> [port]`) and
explains failed connections.

**TLS keys never leave the Mac.** DockZ creates each TLS environment's client
key inside the Mac's Secure Enclave and only shows a certificate signing
request; the server admin signs it with their CA (one command, shown in the
sheet) and the certificate is pasted back. Consequences:

- No private key file exists — not in DockZ's folder, not on the server, not
  in `~/Downloads`. Copying DockZ's data, a backup or the disk yields nothing
  usable; `client-key.se` is a handle only this Mac's chip can use.
- Using the key needs Touch ID (or the login password), enforced by the chip.
  One confirmation unlocks the environment until the screen locks, the Mac
  sleeps or you switch away; listing environments never prompts.
- Client certificates last 90 days (dockerd can't revoke one certificate);
  renew from the sheet. A lost Mac is cut off by replacing the server's CA.
- The docker CLI (compose, Shell) reaches a TLS environment through a private
  relay socket DockZ serves while it is selected (`$TMPDIR/dockz-cli/`, 0600)
  — the CLI never gets certificates or keys.
- The app is signed with the hardened runtime, so other code can't be
  injected into DockZ to borrow its access.

Windows engines work too — Windows containers are listed and managed through
the same API; Linux-only options are hidden for them.

Check an environment from the terminal: `DockZ env-probe ssh user@host [port]`
(or `tls <host> <port> <cert-dir> [--relay SECONDS]`, `socket <path>`). The
TLS probe reads `ca.pem`, `cert.pem` and a `key.pem` from the given folder —
it is meant for test engines.

## Data files

Everything lives under the data folder (default `~/.dockz/`, relocatable in
Settings):

| File / dir     | Purpose                                                        |
| -------------- | -------------------------------------------------------------- |
| `disk.img`     | VM disk (sparse; grows up to the configured disk limit)        |
| `docker.sock`  | Host-side Docker socket (bridged to the guest over vsock)      |
| `console.log`  | Guest serial console — first stop for boot debugging           |
| `host.log`     | Host-side VM lifecycle log (state changes, stop/poweroff path) |
| `config.json`  | cpus, memoryGiB, diskLimitGB, shareHomeDirectory, enableRosetta |
| `bin/`, `docker-config/` | Managed docker CLI + its compose plugin and contexts |
| `environments.json`, `environments/<id>/` | Other Docker engines (0600); a TLS environment's public `ca.pem` / `cert.pem` and Secure Enclave key handle `client-key.se` |
| `snapshots/`   | VM disk snapshots + `index.json`                               |
| `machines/`    | Multipass-style Linux machines (`machines/bases/` = distro images) |

## Testing

The Command Line Tools don't ship XCTest, so tests run as an in-process
subcommand of the app binary:

```bash
swift run -c release DockzApp test    # exits non-zero on failure
```

CI runs the same on a `macos-15` runner (`.github/workflows/ci.yml`).

## Notes

- The app must be signed with the `com.apple.security.virtualization`
  entitlement or the VM won't start — `scripts/build-and-bundle-app.sh` handles
  this (Apple Development certificate, or ad-hoc as a fallback).
- Rebuilding the guest image wipes Docker data (`--force` guard).
- Release DMGs are notarized only when the repository has Developer ID and
  notary secrets ([docs/deployment-guide.md](docs/deployment-guide.md));
  otherwise allow DockZ once in System Settings → Privacy & Security, or run
  `xattr -dr com.apple.quarantine /Applications/DockZ.app`.

## FAQ

**Is DockZ a free Docker Desktop alternative for Mac?**
Yes — free and Apache-2.0 licensed, with no per-seat licensing for companies.
It runs the real Docker Engine (`dockerd`) in a lightweight Alpine Linux VM on
Apple's Virtualization.framework.

**How is DockZ different from OrbStack or Colima?**
OrbStack is excellent but closed-source and paid for commercial use; Colima is
free but CLI-only and installed via Homebrew. DockZ is a ~8 MB fully
open-source native app with a GUI dashboard, needs no Homebrew and no admin
password, and also manages general-purpose Linux VMs. See the
[comparison](#why-dockz).

**Can I run Kubernetes (k3s/k8s) on it?**
Yes — the Machines tab creates Alpine/Debian/Ubuntu VMs with one-click k3s or
kubeadm master/node templates; nodes share one NAT network, so multi-node
clusters work on a single Mac.

**Does `docker compose` / buildx / amd64 work?**
Yes. The engine is upstream Docker, so compose, buildx, and private registries
behave exactly as on Linux. `linux/amd64` images run through Rosetta.

**Do I need Docker or Homebrew installed first?**
No. First launch builds the guest image itself and downloads the official
`docker` CLI + compose plugin, checksum-verified — a fresh Mac goes from zero
to `docker ps` in one window.

## License

DockZ is released under the [Apache License 2.0](LICENSE) — © 2026 The DockZ
Authors. See [NOTICE](NOTICE) for attribution.

Apache 2.0 was chosen for its explicit patent grant (protecting the project and
its users) and its "state changes" requirement on modified files.

The guest images DockZ builds bundle their own separately-licensed software
(Alpine Linux, Debian, Ubuntu, Docker, k3s, etc.); those retain their respective
upstream licenses.
