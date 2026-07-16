# Dockz

A minimal Docker Desktop alternative for Apple silicon Macs, built directly on
Apple's Virtualization.framework. A menu bar app boots a tiny Alpine Linux VM
running the real dockerd and exposes it to the host as a normal docker context.

## Architecture

- **Host app (Swift, menu bar)** — `sources/dockz/`
  - VZ VM: EFI boot → virtio-blk disk, NAT network, virtiofs share of `$HOME`
    at the same path (fast bind mounts), vsock, Rosetta directory share
    (amd64 images), balloon + entropy, serial console → `~/.dockz/console.log`.
  - `~/.dockz/docker.sock` — every client connection is bridged over vsock
    port 2375 to dockerd's unix socket in the guest.
  - Port forwarding — subscribes to the Docker `/events` API, lists published
    ports and mirrors them on `localhost` (TCP), relaying to the guest IP.
  - Creates the `dockz` docker CLI context automatically.
- **Guest (Alpine)** — `guest/`
  - `linux-virt` kernel, grub arm64-efi (standalone image, `--removable` layout),
    openrc, dockerd + compose plugin.
  - Agents are just socat: vsock 2375 → `/var/run/docker.sock`, 2376 → report
    eth0 IP, 2377 → graceful poweroff.
  - First boot grows the root partition to fill the (sparse) 64G disk.
  - Rosetta binfmt registration when the host shares the `rosetta` tag.

## Build

```bash
# 1. Host app (SPM, no Xcode needed)
scripts/build-and-bundle-app.sh       # builds + signs build/Dockz.app

# 2. Guest disk image — pick one:
#    a) Standalone (no Docker anywhere): boots an Alpine netboot VM with
#       Virtualization.framework and provisions the disk over serial.
build/Dockz.app/Contents/MacOS/Dockz build-image
#    b) With any working docker daemon (dockz itself works once installed):
guest/build-guest-image.sh            # installs ~/.dockz/disk.img

# 3. Run
open build/Dockz.app
```

## Use

```bash
docker context use dockz    # or: docker --context dockz …
docker run --rm hello-world
docker run --rm -p 8080:80 nginx   # reachable at localhost:8080
```

Files live in `~/.dockz/`: `disk.img` (VM disk, sparse 64G), `docker.sock`,
`console.log` (guest serial console — first stop for boot debugging),
`config.json` (cpus, memoryGiB, shareHomeDirectory, enableRosetta).

## Notes

- The app must be signed with the `com.apple.security.virtualization`
  entitlement or the VM will not start (`scripts/build-and-bundle-app.sh` does
  this with the local Apple Development certificate).
- Rebuilding the guest image wipes docker data (`--force` guard).
- UDP port forwarding is not implemented (TCP only).

## License

DockZ is released under the [Apache License 2.0](LICENSE) — © 2026 The DockZ Authors.
See [NOTICE](NOTICE) for attribution and third-party components.

Apache 2.0 was chosen for its explicit patent grant (protecting the project and
its users) and its "state changes" requirement on modified files.

DockZ has **no external Swift dependencies** — everything is Apple frameworks
or written in-repo, so builds are fully offline. Interactive shells (SSH into
machines, `docker exec`) open in the system Terminal.app.

The guest images DockZ builds bundle their own separately-licensed software
(Alpine Linux, Debian, Ubuntu, Docker, k3s, etc.); those retain their
respective upstream licenses.
