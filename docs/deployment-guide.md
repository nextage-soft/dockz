# Signing, notarizing and releasing DockZ

DockZ runs a virtual machine, so whatever signs it must also grant the
`com.apple.security.virtualization` entitlement (in
[`scripts/dockz.entitlements`](../scripts/dockz.entitlements)). Without it the
app opens but the VM never starts. Every signing command below passes that file.

| You are… | Read |
| --- | --- |
| A user who downloaded a release | [1. Running a release](#1-running-a-release) |
| A user who wants DockZ signed with their own certificate | [2. Signing it yourself](#2-signing-it-yourself) |
| Publishing releases (this repo or a fork) | [3. Signed + notarized releases from GitHub Actions](#3-signed--notarized-releases-from-github-actions) |
| Building a release on your own Mac | [4. Signing and notarizing locally](#4-signing-and-notarizing-locally) |

---

## 1. Running a release

1. Download `DockZ-<version>.dmg` from
   [Releases](https://github.com/nextage-soft/dockz/releases) and, optionally,
   check it against the published `.sha256`:
   ```bash
   cd ~/Downloads && shasum -a 256 -c DockZ-0.2.3.dmg.sha256
   ```
2. Open the DMG and drag **DockZ** onto **Applications**.
3. Launch DockZ. The first launch builds the Docker VM image (a few minutes).

**Or with Homebrew** (installs the same latest release):
```bash
brew tap nextage-soft/dockz https://github.com/nextage-soft/dockz
brew install --cask nextage-soft/dockz/dockz
brew upgrade --cask --greedy dockz      # later, to update
```

**If macOS says DockZ "cannot be opened" / "Apple could not verify…"** the
release was not notarized. Either:

- open **System Settings → Privacy & Security**, scroll to the message about
  DockZ and click **Open Anyway** (once), or
- remove the download quarantine flag:
  ```bash
  xattr -dr com.apple.quarantine /Applications/DockZ.app
  ```

Notarized releases (the release notes don't carry the "not notarized" warning)
open without either step.

---

## 2. Signing it yourself

Useful when your organisation only allows apps signed by a certificate it
trusts, or you want a stable signature across updates. Any of these works:

**Ad-hoc (no Apple account):**
```bash
codesign --force --options runtime --sign - \
  --entitlements /path/to/dockz/scripts/dockz.entitlements \
  /Applications/DockZ.app
```

**Your own certificate** ("Apple Development" or "Developer ID Application",
listed by `security find-identity -v -p codesigning`):
```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --entitlements /path/to/dockz/scripts/dockz.entitlements \
  /Applications/DockZ.app
codesign --verify --strict --verbose=2 /Applications/DockZ.app
```

No local checkout? Save this as `dockz.entitlements` and use it instead:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
```

What changes when you re-sign:

- Quit DockZ first (its VM stops), sign, then relaunch.
- Registry passwords live in the Keychain bound to the app's signature;
  macOS asks once to allow the re-signed app to read them.
- TLS environment keys live in the Secure Enclave and are not tied to the
  signature — they keep working.
- Re-signing after every update is needed: an update replaces the app with
  the release's own signature.

---

## 3. Signed + notarized releases from GitHub Actions

[`.github/workflows/release.yml`](../.github/workflows/release.yml) runs when a
tag `v*` is pushed: tests → `build-and-bundle-app.sh` → `make-dmg.sh` →
notarization → GitHub Release with the DMG and its SHA-256. Signing turns on
only when the secrets below exist; otherwise the release is ad-hoc signed
(section 1 applies to users).

Requires a paid [Apple Developer Program](https://developer.apple.com/programs/)
membership.

### 3.1 Developer ID certificate → `DEVELOPER_ID_P12_*`

1. Create the certificate: **Xcode → Settings → Accounts →** select the team →
   **Manage Certificates… → + → Developer ID Application**.
   (Without Xcode: developer.apple.com → Certificates → +, upload a CSR made in
   Keychain Access → Certificate Assistant → *Request a Certificate From a
   Certificate Authority*, then double-click the downloaded `.cer`.)
2. Export it **with its private key**: Keychain Access → *login* → *My
   Certificates* → right-click "Developer ID Application: …" → **Export…** →
   `DeveloperID.p12`, choose a strong password.
3. Add both secrets (with the [GitHub CLI](https://cli.github.com), from the repo):
   ```bash
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
   gh secret set DEVELOPER_ID_P12_PASSWORD     # paste the .p12 password
   rm DeveloperID.p12
   ```
   (Or **Settings → Secrets and variables → Actions → New repository secret**.)

### 3.2 Notarization API key → `NOTARY_*`

1. [App Store Connect](https://appstoreconnect.apple.com) → **Users and Access
   → Integrations → App Store Connect API → Team Keys → +**, access
   **Developer**. Download `AuthKey_XXXXXXXXXX.p8` — it can be downloaded only
   once. Note the **Key ID** and the **Issuer ID** shown above the list.
2. Add the secrets:
   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8_BASE64
   gh secret set NOTARY_KEY_ID --body XXXXXXXXXX
   gh secret set NOTARY_ISSUER_ID --body 00000000-0000-0000-0000-000000000000
   ```
   Keep the `.p8` somewhere safe (a password manager), not in the repo.

### 3.3 Publish

```bash
git tag v0.2.0 && git push origin v0.2.0
```

Watch **Actions → Release**. The *Import Developer ID certificate* and
*Notarize* steps run only when their secrets exist; *Notarize* ends with
`spctl` accepting the DMG. A manual run (**Run workflow**) builds a DMG artifact
without creating a release — handy to test the secrets.

The tag must look like `v1.2.3` (it becomes `CFBundleShortVersionString`). Re-running
the workflow for an existing tag replaces the release's files.

---

## 4. Signing and notarizing locally

```bash
# Sign with your identity (ad-hoc "-" if unset and no Apple Development cert)
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
APP_VERSION=0.2.0 BUILD_NUMBER=1 scripts/build-and-bundle-app.sh
scripts/make-dmg.sh                       # → build/DockZ-0.2.0.dmg (signed too)

# One-time: store the API key in the login keychain
xcrun notarytool store-credentials dockz-notary \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-id>

xcrun notarytool submit build/DockZ-0.2.0.dmg --keychain-profile dockz-notary --wait
xcrun stapler staple build/DockZ-0.2.0.dmg
```

### Verify

```bash
codesign -dv --verbose=4 /Applications/DockZ.app     # flags=…(runtime), Authority=Developer ID…
codesign -d --entitlements - /Applications/DockZ.app # must list …virtualization
spctl -a -vv -t install build/DockZ-0.2.0.dmg        # "accepted, source=Notarized Developer ID"
```

### Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| App opens, VM never starts | Signed without `--entitlements scripts/dockz.entitlements`. Re-sign with it. |
| Notary: "The signature does not include a secure timestamp" | Sign with `--timestamp` (the build script adds it for Developer ID identities). |
| Notary: "The executable does not have the hardened runtime enabled" | Sign with `--options runtime`. |
| Notary status *Invalid* | `xcrun notarytool log <submission-id> --keychain-profile dockz-notary` lists each problem. |
| CI: "no Developer ID Application identity in the .p12" | The export lacked the private key, or the certificate is "Apple Development". Re-export from *My Certificates*. |
