# Security Policy

## Supported versions

Only the latest release (and `master`) receive security fixes.

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** on this repository
(Security tab → Report a vulnerability) instead of opening a public issue.

You should get a first response within a few days. Please include steps to
reproduce and, if relevant, whether the issue is in the host app, the guest
image, or the image-build path.

DockZ runs a VM with the `com.apple.security.virtualization` entitlement,
bridges a Docker socket, and downloads pinned binaries at install time — those
areas are the most security-sensitive and reports there are especially
appreciated.
