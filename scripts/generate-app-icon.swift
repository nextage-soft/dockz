#!/usr/bin/env swift
// Generates build/AppIcon.icns — macOS-style squircle: deep blue gradient,
// subtle waves, white shipping box with soft shadow.
import AppKit

func drawIcon(canvas: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    let margin = canvas * 0.095
    let rect = NSRect(x: margin, y: margin, width: canvas - 2 * margin, height: canvas - 2 * margin)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Background gradient
    NSGradient(colors: [
        NSColor(calibratedRed: 0.25, green: 0.58, blue: 0.99, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.26, blue: 0.68, alpha: 1),
    ])?.draw(in: squircle, angle: -65)

    // Waves at the bottom (clipped to the squircle)
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    for (index, alpha) in [0.16, 0.10, 0.06].enumerated() {
        let wave = NSBezierPath()
        let waveHeight = rect.height * (0.16 + CGFloat(index) * 0.085)
        let baseline = rect.minY + waveHeight
        let amplitude = rect.height * 0.035
        wave.move(to: NSPoint(x: rect.minX, y: baseline))
        var x = rect.minX
        var up = index % 2 == 0
        while x < rect.maxX {
            let next = x + rect.width / 3
            wave.curve(
                to: NSPoint(x: next, y: baseline),
                controlPoint1: NSPoint(x: x + rect.width / 6, y: baseline + (up ? amplitude : -amplitude)),
                controlPoint2: NSPoint(x: x + rect.width / 6, y: baseline + (up ? amplitude : -amplitude))
            )
            x = next
            up.toggle()
        }
        wave.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        wave.line(to: NSPoint(x: rect.minX, y: rect.minY))
        wave.close()
        NSColor.white.withAlphaComponent(alpha).setFill()
        wave.fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    // Shipping box symbol, white, soft shadow
    let config = NSImage.SymbolConfiguration(pointSize: canvas * 0.46, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        let symbolRect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: symbolRect)
        symbolRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = canvas * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.012)
        shadow.set()
        let drawRect = NSRect(
            x: (canvas - symbol.size.width) / 2,
            y: (canvas - symbol.size.height) / 2 + canvas * 0.02,
            width: symbol.size.width,
            height: symbol.size.height
        )
        tinted.draw(in: drawRect)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(fileURLWithPath: "build/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: output)
try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]
let master = drawIcon(canvas: 1024)
for (pixels, suffix) in variants {
    writePNG(master, pixels: pixels, to: output.appendingPathComponent("icon_\(suffix).png"))
}
print("iconset written to \(output.path)")
