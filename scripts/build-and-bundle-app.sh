#!/bin/bash
# Builds the Dockz host app with SPM, bundles it into build/Dockz.app and
# codesigns it with the virtualization entitlement (required for VZ to boot).
set -euo pipefail
# Never fail silently: with pipefail a lookup that legitimately finds nothing
# (grep without a match) ends the script, so say where it stopped.
trap 'echo "error: ${BASH_SOURCE[0]}:$LINENO: \`$BASH_COMMAND\` failed" >&2' ERR
cd "$(dirname "$0")/.."

# Signing identity: use $SIGN_IDENTITY if set, else the first "Apple
# Development" certificate on this machine, else fall back to ad-hoc ("-").
# The VM needs the com.apple.security.virtualization entitlement, which is
# carried even by an ad-hoc signature for local development. Machines with no
# certificate at all (CI runners) are normal, not an error.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    AUTO_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | { grep 'Apple Development' || true; } | head -1 | sed -E 's/.*"(.*)"$/\1/')"
    SIGN_IDENTITY="${AUTO_IDENTITY:--}"
fi

# The macOS 27+ SDK turns SwiftUI @State into a macro whose compiler plugin
# (SwiftUIMacros) does not ship with Command Line Tools. When building with
# CLT only (no full Xcode), pin to the newest installed SDK below major 27.
# Respects an explicit $SDKROOT and is a no-op where a full Xcode toolchain is
# present (e.g. CI runners), which have the plugin. Robust to Apple shipping a
# 26.6 SDK etc. — it no longer hardcodes 26.5.
if [[ -z "${SDKROOT:-}" ]]; then
    for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null \
                 | sort -Vr); do
        major="$(basename "$sdk" | sed -E 's/MacOSX([0-9]+).*/\1/')"
        if [[ "$major" =~ ^[0-9]+$ && "$major" -lt 27 ]]; then
            export SDKROOT="$sdk"
            echo "Using pinned SDK: $sdk"
            break
        fi
    done
fi

swift build -c release

APP="build/DockZ.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DockzApp "$APP/Contents/MacOS/DockZ"
# Drop local symbols (keeps exported ones): BoringSSL from swift-nio-ssl
# roughly doubles the unstripped binary (16.6 → 8.0 MB measured 2026-10-01).
strip -x "$APP/Contents/MacOS/DockZ"
# Bundle the guest config so `Dockz build-image` works from anywhere.
cp -R guest "$APP/Contents/Resources/guest"
rm -rf "$APP/Contents/Resources/guest/work"

# App icon (generate once; delete build/AppIcon.icns to force a redraw).
if [[ ! -f build/AppIcon.icns ]]; then
    swift scripts/generate-app-icon.swift
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DockZ</string>
    <key>CFBundleDisplayName</key>
    <string>DockZ</string>
    <key>CFBundleIdentifier</key>
    <string>com.nextagesoft.dockz</string>
    <key>CFBundleExecutable</key>
    <string>DockZ</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0</string>
    <key>CFBundleVersion</key>
    <string>0</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Dockz forwards published container ports to the Docker VM over the local NAT network.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Dockz Dashboard</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>dockz</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Version stamp. Release CI passes APP_VERSION / BUILD_NUMBER from the tag;
# local builds take them from git — the latest v* tag and the commit count —
# so a local build never shows a stale hardcoded version (it used to say
# 0.1.0 long after 0.2.1 shipped).
if [[ -z "${APP_VERSION:-}" ]]; then
    APP_VERSION="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)"
    APP_VERSION="${APP_VERSION:-0.0.0}"
fi
if [[ -z "${BUILD_NUMBER:-}" ]]; then
    BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
echo "Version: $APP_VERSION ($BUILD_NUMBER)"

# Hardened runtime: macOS refuses injected libraries (DYLD_INSERT_LIBRARIES)
# and debugger attachment, so other code can't ride inside DockZ to use what
# it is trusted with (Secure Enclave keys, keychain items, the VM).
# Notarization also requires a secure timestamp on Developer ID signatures.
TIMESTAMP_FLAG=()
[[ "$SIGN_IDENTITY" == "Developer ID Application"* ]] && TIMESTAMP_FLAG=(--timestamp)
codesign --force --options runtime "${TIMESTAMP_FLAG[@]+"${TIMESTAMP_FLAG[@]}"}" --sign "$SIGN_IDENTITY" \
    --entitlements scripts/dockz.entitlements \
    "$APP"

echo "Built and signed: $APP"
