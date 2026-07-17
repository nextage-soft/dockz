# Contributing to DockZ

Thanks for helping! DockZ is small on purpose — a few ground rules keep it that
way.

## Ground rules

- **Zero external Swift dependencies.** Only Apple frameworks and code in this
  repo. PRs adding a package dependency will be declined — implement it or
  propose it in an issue first.
- **File naming**: kebab-case, long and descriptive
  (`docker-socket-bridge.swift`, not `Bridge.swift`).
- **Comments** explain constraints the code can't show, not what the next line
  does.
- One logical change per PR; squash-merge keeps history linear.

## Building

Command Line Tools are enough — no full Xcode required:

```bash
scripts/build-and-bundle-app.sh     # build + sign → build/DockZ.app
open build/DockZ.app
```

If your Mac has only Command Line Tools and the newest macOS SDK, the script
pins `SDKROOT` automatically (the SwiftUI macro plugin doesn't ship with CLT).
See the README's *Code signing* section for identity options.

## Testing

XCTest doesn't ship with the Command Line Tools, so tests are an in-process
subcommand:

```bash
swift run -c release DockzApp test    # must print ALL TESTS PASSED
```

Add checks to `sources/dockz/test-runner.swift` for any new pure logic. CI
(`build-and-test`) runs the same command and must pass before merge.

For changes touching the VM lifecycle, `~/.dockz/host.log` and
`~/.dockz/console.log` are your first diagnostic stops; a root debug shell in
the guest is one `nc -U ~/.dockz/debug-shell.sock` away.

## Pull requests

1. Fork, branch from `master`, make the change.
2. `swift run -c release DockzApp test` passes locally.
3. Open the PR — CI must be green; the maintainer reviews and squash-merges.
4. For big features, open an issue first so we agree on the approach — see the
   feature specs in `docs/` for the level of detail that helps.

## Reporting security issues

Please don't open public issues for vulnerabilities — see
[SECURITY.md](SECURITY.md).
