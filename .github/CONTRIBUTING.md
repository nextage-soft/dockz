# Contributing to DockZ

Contributions are welcome: bug reports, fixes, docs, translations and features.
You don't need to ask before sending a small fix; for anything bigger, open an
issue first so we agree on the approach before you spend the time.

## Where to start

- **Bugs**: open an issue with the *Bug report* template. Attach `host.log` and
  `console.log` from the data folder (menu bar → *Open ~/.dockz Folder*) if the
  VM is involved — check them for anything private first.
- **Ideas**: open an issue with the *Feature request* template.
- **Looking for something to do**: issues labelled
  [`good first issue`](https://github.com/nextage-soft/dockz/labels/good%20first%20issue)
  are small and self-contained;
  [`help wanted`](https://github.com/nextage-soft/dockz/labels/help%20wanted)
  ones are larger. Comment on the issue to say you're taking it.
- **Docs and website** (`README*.md`, `docs/`, `landing/`): no Mac build needed;
  CI skips the macOS build for PRs that touch only these.

## Ground rules

DockZ is small on purpose — these keep it that way.

- **Dependencies**: Apple frameworks plus Apple's `swift-nio` / `swift-nio-ssl`
  (TLS only), pinned exactly in `Package.swift`. Adding any other package needs
  an issue first; most things are better written here.
- **File naming**: kebab-case, long and descriptive
  (`docker-socket-bridge.swift`, not `Bridge.swift`).
- **Comments** explain constraints the code can't show, not what the next line
  does.
- One logical change per PR; squash-merge keeps history linear. Add a line to
  the `[Unreleased]` section of `CHANGELOG.md` for anything users would notice.

## Building

You need an Apple Silicon Mac. Command Line Tools are enough — no full Xcode
required:

```bash
scripts/build-and-bundle-app.sh     # build + sign → build/DockZ.app
open build/DockZ.app
```

If your Mac has only Command Line Tools and the newest macOS SDK, the script
pins `SDKROOT` automatically (the SwiftUI macro plugin doesn't ship with CLT).
See the README's *Code signing* section for identity options.

To try your build without touching your own Docker data, give it a separate
data folder (keep the path short — socket paths are limited to 103 bytes):

```bash
open -n build/DockZ.app --args -dockz.storageRoot /tmp/dz-dev
```

## Testing

XCTest doesn't ship with the Command Line Tools, so tests are an in-process
subcommand:

```bash
swift run -c release DockzApp test    # must print ALL TESTS PASSED
```

Add checks for any new pure logic in a `sources/dockz/test-runner-<area>.swift`
file and call it from `test-runner.swift`. CI (`build-and-test`) runs the same
command and must pass before merge.

For changes touching the VM lifecycle, `host.log` and `console.log` in the data
folder are your first diagnostic stops; a root debug shell in the guest is one
`nc -U <data folder>/debug-shell.sock` away.

## Pull requests

1. Fork, branch from `master`, make the change.
2. `swift run -c release DockzApp test` passes locally.
3. Open the PR and fill in the template — especially *How I verified it*.
4. CI must be green. On your first PR, a maintainer approves the CI run before
   it starts (GitHub's rule for first-time contributors).
5. Review comments must be resolved and the branch up to date with `master`;
   the maintainer squash-merges.

By contributing you agree that your work is licensed under the project's
[Apache-2.0 license](/LICENSE).

## Code of conduct and security

Be kind — see the [Code of Conduct](/.github/CODE_OF_CONDUCT.md). Please don't open
public issues for vulnerabilities — see [SECURITY.md](/.github/SECURITY.md).
