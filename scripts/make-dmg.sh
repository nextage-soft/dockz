#!/bin/bash
# Packs build/DockZ.app (from build-and-bundle-app.sh) into a drag-to-install
# disk image: build/DockZ-<version>.dmg with the app and an /Applications link.
# Signs the image too when SIGN_IDENTITY is a Developer ID (needed before
# notarizing the DMG). Prints the DMG path on the last line.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DockZ.app"
[[ -d "$APP" ]] || { echo "error: $APP missing — run scripts/build-and-bundle-app.sh first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/DockZ-${DMG_LABEL:-$VERSION}.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
# ditto keeps the code signature and extended attributes intact.
ditto "$APP" "$STAGING/DockZ.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "DockZ ${VERSION}" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

if [[ "${SIGN_IDENTITY:-}" == "Developer ID Application"* ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

hdiutil verify "$DMG" >/dev/null
echo "$DMG"
