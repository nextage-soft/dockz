# Homebrew cask for DockZ, kept in this repository (no separate tap repo):
#   brew tap nextage-soft/dockz https://github.com/nextage-soft/dockz
#   brew install --cask nextage-soft/dockz/dockz
# It always installs the newest GitHub release: the Release workflow attaches
# a stable-named DockZ.dmg next to DockZ-<version>.dmg, so this file never
# needs a per-release bump. Each release also publishes the DMG's SHA-256.
cask "dockz" do
  version :latest
  sha256 :no_check

  url "https://github.com/nextage-soft/dockz/releases/latest/download/DockZ.dmg"
  name "DockZ"
  desc "Docker and Linux VMs on Apple Silicon, natively"
  homepage "https://dockz.nextagesoft.com/"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "DockZ.app"

  # Quitting DockZ shuts its VM down cleanly before the app is replaced.
  uninstall quit: "com.nextagesoft.dockz"

  # Only with `brew uninstall --zap`: ~/.dockz holds the VM disk, i.e. all
  # Docker images, containers and volumes. (A data folder moved elsewhere in
  # Settings is not removed.)
  zap trash: [
    "~/.dockz",
    "~/Library/Preferences/com.nextagesoft.dockz.plist",
    "~/Library/Saved Application State/com.nextagesoft.dockz.savedState",
  ]

  caveats <<~EOS
    Until DockZ releases are notarized, macOS blocks the first launch:
    open System Settings → Privacy & Security and click "Open Anyway".

    DockZ tracks the latest release; update with:
      brew upgrade --cask --greedy dockz

    `brew uninstall --zap dockz` also deletes ~/.dockz — the VM disk with all
    Docker images, containers and volumes.
  EOS
end
