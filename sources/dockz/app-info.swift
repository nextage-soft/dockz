import Foundation

/// Central project metadata. Version numbers come from the app bundle
/// (Info.plist, set by scripts/build-and-bundle-app.sh) so there is a single
/// source of truth; the rest is static project identity shown in the About page.
enum AppInfo {
    static let name = "DockZ"
    static let tagline = "Docker & Linux VMs on Apple Silicon, natively."
    static let summary = """
    A Docker Desktop / Colima / Multipass alternative for macOS on Apple Silicon, \
    built entirely on Apple's Virtualization.framework — no external runtimes, no \
    Swift dependencies. Runs a lightweight Alpine VM for the Docker engine and can \
    spin up full Linux machines (Alpine / Debian / Ubuntu) with optional k3s/k8s clusters.
    """

    static let homepage = "https://github.com/tieuanhquoc/dockz"
    static let license = "Apache License 2.0"
    static let copyright = "© 2026 The DockZ Authors"

    /// Marketing version, e.g. "0.1.0" (CFBundleShortVersionString).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Build number, e.g. "1" (CFBundleVersion).
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// Minimum macOS this build declares (LSMinimumSystemVersion).
    static var minimumSystem: String {
        Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "15.0"
    }

    /// "0.1.0 (1)" — version with build, for compact display.
    static var versionLong: String { "\(version) (\(build))" }

    /// Human-readable OS the app is running on, e.g. "macOS 15.3".
    static var runningOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }
}
