# Changelog

Notable changes to DockZ. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/). Each release's notes on GitHub
are taken from its section here.

## [Unreleased]

## [0.2.0] - 2026-10-05

The first downloadable release: grab `DockZ-0.2.0.dmg` from the release assets.

### Added
- **Multiple environments** — manage other Docker engines from the same window: remote hosts
  over SSH or mutual TLS, or another engine's socket on this Mac (Colima, OrbStack, Docker
  Desktop). Every tab follows the environment picked in the sidebar (⌘1…⌘9); DockZ always
  opens on Local, and remote engines get an orange header and host-named confirmations.
  Windows engines are supported.
- **TLS keys in the Secure Enclave** — each TLS environment's client key is created inside the
  Mac's chip and used with Touch ID; only a signing request leaves the Mac. 90-day client
  certificates; the docker CLI reaches TLS engines through a private relay socket.
- **Setup guide in the app** for SSH, TLS and socket environments, failure hints, and the
  `DockZ env-guide` / `DockZ env-probe` commands.
- **Monitor tab** — live CPU, memory, network and disk per container, VM vitals, a storage
  breakdown, and cleanup of unused images, volumes and build cache.
- **Filters on every list** — scope chips with counts, multi-word search and sort; containers
  grouped by compose stack, crashes and unhealthy checks flagged. ⌘F / ⌘R / ⌘N.
- **Self-healing VM** — if the guest kernel fails or dockerd stops answering, DockZ restarts the
  VM by itself (crash-loop limited) and keeps the console logs of the last 5 boots.
- Portainer-style container detail page, advanced container settings as form fields,
  multi-network containers, launch at login.
- VM time zone setting (follows the Mac by default).
- Release DMG built by GitHub Actions, optionally Developer ID–signed and notarized;
  [signing guide](docs/deployment-guide.md) for running or re-signing it yourself.

### Changed
- Published ports bind to the address Docker reports, so the default `0.0.0.0` is reachable
  from the LAN.
- Docker engine settings (`daemon.json`) moved to **Settings → Advanced**.
- The app is signed with the hardened runtime; TLS uses Apple's swift-nio-ssl.
- The dashboard refreshes on Docker events instead of polling every 4 seconds.

### Fixed
- Crash in the Monitor disk breakdown when Docker reports `-1` for an unknown size.
- Snapshot name field squeezed by its form label.

## [0.1.0] - 2026-07-16

Initial version, build from source only: the real `dockerd` in an Alpine VM on
Virtualization.framework, Docker Desktop–style dashboard, Multipass-style Linux machines with
k3s/k8s templates, automatic port forwarding, VM snapshots, Rosetta, Docker CLI on demand.

[Unreleased]: https://github.com/nextage-soft/dockz/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/nextage-soft/dockz/releases/tag/v0.2.0
[0.1.0]: https://github.com/nextage-soft/dockz/commit/3bed5ae
