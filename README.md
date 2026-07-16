# DockZ

**Docker & Linux VMs on Apple Silicon, natively.**

DockZ is a Docker Desktop / Colima / Multipass alternative for macOS on Apple
Silicon, built entirely on Apple's **Virtualization.framework** — no external
runtimes, no Swift dependencies, fully offline builds. A menu bar app boots a
tiny Alpine Linux VM running the real `dockerd` and exposes it to the host as a
normal Docker context, plus a Docker Desktop–style dashboard and Multipass-style
Linux machines.

![platform](https://img.shields.io/badge/platform-macOS%2015%2B%20·%20Apple%20Silicon-black)
![license](https://img.shields.io/badge/license-Apache%202.0-blue)
![dependencies](https://img.shields.io/badge/Swift%20dependencies-none-success)

---

## Features

- **Real Docker engine in a VM** — genuine `dockerd` in Alpine Linux, reachable
  as the `dockz` Docker context. `docker`, `docker compose`, buildx all work.
- **Management dashboard** (Docker Desktop / Portainer style) — containers,
  images, volumes, networks, registries, and compose **stacks**, with full
  create/edit forms, live logs, stats, and inspect.
- **Multipass-style machines** — spin up full Linux VMs (Alpine / Debian /
  Ubuntu, ARM64) with optional **k3s / k8s** cluster templates (master/node
  roles), reachable over SSH.
- **TCP + UDP port forwarding** — published container ports are mirrored on
  `localhost` automatically by watching the Docker events API.
- **VM snapshots** — instant APFS copy-on-write snapshots of the VM disk you can
  roll back to.
- **Rosetta** — run `linux/amd64` images on Apple Silicon.
- **Configurable** — CPUs, memory, disk limit, `$HOME` virtiofs share, and a
  relocatable data folder (put large disks on an external SSD).
- **Zero external dependencies** — only Apple frameworks and in-repo code.
  Interactive shells (SSH, `docker exec`) open in the system Terminal.app.

## Requirements

- macOS **15 (Sequoia) or later**
- **Apple Silicon** (M1 or newer)
- Command Line Tools or Xcode (to build from source)

## Install / Build

No full Xcode required — DockZ builds with Swift Package Manager and a bundling
script.

```bash
# 1. Build + sign the host app  →  build/DockZ.app
scripts/build-and-bundle-app.sh

# 2. Build the guest disk image — pick one:
#    a) Standalone (no Docker needed anywhere): boots an Alpine netboot VM and
#       provisions the disk over the serial console.
build/DockZ.app/Contents/MacOS/DockZ build-image
#    b) With any working Docker daemon already available:
guest/build-guest-image.sh            # installs <data folder>/disk.img

# 3. Run
open build/DockZ.app
```

Copy `build/DockZ.app` into `/Applications` to install.

## Usage

```bash
docker context use dockz            # or: docker --context dockz …
docker run --rm hello-world
docker run --rm -p 8080:80 nginx    # reachable at http://localhost:8080
```

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
- **Guest (Alpine)** — `guest/`
  - `linux-virt` kernel, grub arm64-efi (standalone, `--removable`), OpenRC,
    `dockerd` + compose plugin.
  - Agents are just `socat`: vsock 2375 → `/var/run/docker.sock`, 2376 → report
    `eth0` IP, 2377 → graceful poweroff, 2378 → debug shell.
  - First boot grows the root partition to fill the (sparse) disk.
  - Rosetta binfmt registration when the host shares the `rosetta` tag.

## Data files

Everything lives under the data folder (default `~/.dockz/`, relocatable in
Settings):

| File / dir     | Purpose                                                        |
| -------------- | -------------------------------------------------------------- |
| `disk.img`     | VM disk (sparse; grows up to the configured disk limit)        |
| `docker.sock`  | Host-side Docker socket (bridged to the guest over vsock)      |
| `console.log`  | Guest serial console — first stop for boot debugging           |
| `config.json`  | cpus, memoryGiB, diskLimitGB, shareHomeDirectory, enableRosetta |
| `snapshots/`   | VM disk snapshots + `index.json`                               |
| `machines/`    | Multipass-style Linux machines                                 |

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
- Not yet notarized — Gatekeeper may require right-click → Open on first launch,
  or `xattr -dr com.apple.quarantine /Applications/DockZ.app`.

## License

DockZ is released under the [Apache License 2.0](LICENSE) — © 2026 The DockZ
Authors. See [NOTICE](NOTICE) for attribution.

Apache 2.0 was chosen for its explicit patent grant (protecting the project and
its users) and its "state changes" requirement on modified files.

The guest images DockZ builds bundle their own separately-licensed software
(Alpine Linux, Debian, Ubuntu, Docker, k3s, etc.); those retain their respective
upstream licenses.
