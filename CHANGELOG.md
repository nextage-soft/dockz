# Changelog

Notable changes to DockZ. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/). Each release's notes on GitHub
are taken from its section here.

## [Unreleased]

## [0.2.3] - 2026-10-07

### Changed
- Quitting DockZ (menu bar Quit, ⌘Q, the Dock, or logout) now shows a "Shutting down
  DockZ…" window listing the Docker engine and Linux machines being stopped, with a check
  as each one finishes, instead of seeming frozen for the seconds a clean VM shutdown takes.

- Monitor's disk card shows space used against the disk limit (orange from 80%, red from
  95%) instead of against the filesystem size, with how much space is free on the Mac.
  Settings shows the Mac's free space too.

### Fixed
- The disk limit is now enforced when it is lowered. Before, the VM disk only ever grew, so
  a disk created at 64 GB kept using up to 64 GB after the limit was set to 16 GB. Apply &
  Restart now stops Docker, shrinks the disk offline to the new limit and starts Docker
  again. A safety copy is kept until the shrink succeeds. If the data does not fit, the
  disk is left as it is and the message says which limit would fit. `DockZ shrink-disk`
  does the same from the terminal while DockZ is closed.
- `docker run` (without `-d`), `docker exec` and other attached commands lost any output
  printed more than half a second after they started: `sh -c 'echo start; sleep 3; echo
  end'` showed only "start". The VM's socket relay closed the stream half a second after
  the docker CLI finished sending input. Existing VMs get the fix at their next start: DockZ
  now brings the VM's own DockZ service files up to date with the app on every boot (boot
  files excluded), so later fixes to them reach existing disks too.
- Opening DockZ while its menu bar icon is hidden (a crowded menu bar or the notch) did
  nothing, so the app looked frozen. Opening it again from Finder, Spotlight or Launchpad
  now always shows the dashboard (restoring it if minimised), and a launch you start
  yourself opens it too; only Launch at Login still starts quietly in the menu bar.

## [0.2.2] - 2026-10-07

### Added
- Homebrew cask in this repository: `brew tap nextage-soft/dockz https://github.com/nextage-soft/dockz`
  then `brew install --cask nextage-soft/dockz/dockz`. Releases now also attach a stable-named
  `DockZ.dmg` that the cask installs.
- Vietnamese README (`README.vi.md`) and website (`/vi/`, with `hreflang` links and a
  language switch).
- 34-second intro video on the website (muted, in English and Vietnamese).

### Changed
- New screenshots (v0.2.1, demo data only) in the README and on the website, including
  Monitor and the TLS / Secure Enclave environment editor.
- Architecture diagram no longer claims zero external Swift dependencies (TLS uses Apple's
  swift-nio-ssl) and shows Monitor, the VM watchdog and remote engines.
- Local builds take their version from the latest git tag and the commit count instead of
  a hardcoded 0.1.0.

### Fixed
- A data folder whose path made `docker.sock` longer than macOS allows (103 bytes) left the
  docker CLI without a socket and said nothing; DockZ now shows the reason, and moving the
  data folder refuses such a location up front.
- Two copies of DockZ could run on the same data folder; the second one kept retrying a VM
  that could not start. A data-folder lock now lets only one copy run, and a VM that fails
  to start is reported instead of restarted (a VM that crashes while running is still
  restarted).
- Monitor no longer sits on "Measuring…" for up to a minute, and says it is reading stats
  instead of "No running containers" while they arrive.
- List filter chips no longer wrap mid-word when the header is crowded (seen on Machines);
  the search field shrinks instead.

## [0.2.1] - 2026-10-05

The first downloadable release: grab `DockZ-0.2.1.dmg` from the release assets.

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
- Release build on machines without an Apple Development certificate (CI runners): the
  signing-identity lookup ended the build script silently. Build scripts now report the
  failing line instead of exiting without a message.

## [0.2.0] - 2026-10-05

Tagged but not published: its release build failed (see 0.2.1). Everything it contained
ships in 0.2.1.

## [0.1.0] - 2026-07-16

Initial version, build from source only: the real `dockerd` in an Alpine VM on
Virtualization.framework, Docker Desktop–style dashboard, Multipass-style Linux machines with
k3s/k8s templates, automatic port forwarding, VM snapshots, Rosetta, Docker CLI on demand.

[Unreleased]: https://github.com/nextage-soft/dockz/compare/v0.2.3...HEAD
[0.2.3]: https://github.com/nextage-soft/dockz/releases/tag/v0.2.3
[0.2.2]: https://github.com/nextage-soft/dockz/releases/tag/v0.2.2
[0.2.1]: https://github.com/nextage-soft/dockz/releases/tag/v0.2.1
[0.2.0]: https://github.com/nextage-soft/dockz/tree/v0.2.0
[0.1.0]: https://github.com/nextage-soft/dockz/commit/3bed5ae
