#!/usr/bin/env swift
// Generates the 1280x640 social preview banner used by the README
// (public/social-preview.png) and the site's og:image
// (landing/assets/social-preview.png).
//
// The banner was a hand-made PNG and its tagline went stale ("~5 MB",
// "zero dependencies" — the app bundle is ~8 MB and TLS uses swift-nio-ssl).
// Edit `tagline` below and re-run instead of editing the image:
//
//   swift scripts/generate-app-icon.swift          # icon source, if missing
//   swift scripts/generate-social-preview.swift
import AppKit

let tagline = "~8 MB native app · real dockerd · no Electron · Apache 2.0"
let subtitle = "Docker & Linux VMs on Apple Silicon, natively."
let iconURL = URL(fileURLWithPath: "build/AppIcon.iconset/icon_512x512@2x.png")
let outputs = ["public/social-preview.png", "landing/assets/social-preview.png"]

let width = 1280, height = 640
guard let icon = NSImage(contentsOf: iconURL) else {
    print("missing \(iconURL.path) — run scripts/generate-app-icon.swift first")
    exit(1)
}
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: width, height: height)   // 1 point = 1 pixel

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: width, height: height)

// Deep navy, lighter toward the bottom right.
NSGradient(colors: [
    NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.27, blue: 0.53, alpha: 1),
])?.draw(in: canvas, angle: -25)

// Three soft waves along the bottom, like the icon's.
for (index, alpha) in [0.10, 0.12, 0.14].enumerated() {
    let base = CGFloat(205 - index * 70)
    let wave = NSBezierPath()
    wave.move(to: NSPoint(x: 0, y: 0))
    wave.line(to: NSPoint(x: 0, y: base))
    var x: CGFloat = 0
    let step: CGFloat = 8
    while x <= CGFloat(width) {
        let y = base + 16 * sin((x / CGFloat(width)) * .pi * 2 + CGFloat(index) * 1.3)
        wave.line(to: NSPoint(x: x, y: y))
        x += step
    }
    wave.line(to: NSPoint(x: CGFloat(width), y: 0))
    wave.close()
    NSColor(calibratedRed: 0.55, green: 0.70, blue: 0.95, alpha: alpha).setFill()
    wave.fill()
}

// App icon (its PNG includes the macOS margin around the squircle).
icon.draw(in: NSRect(x: 112, y: 172, width: 296, height: 296))

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, baselineFromTop: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ]
    NSAttributedString(string: text, attributes: attributes)
        .draw(at: NSPoint(x: 462, y: CGFloat(height) - baselineFromTop))
}
draw("DockZ", size: 104, weight: .bold, alpha: 1, baselineFromTop: 292)
draw(subtitle, size: 30, weight: .semibold, alpha: 0.96, baselineFromTop: 358)
draw(tagline, size: 21, weight: .regular, alpha: 0.62, baselineFromTop: 410)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
for path in outputs {
    try png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
