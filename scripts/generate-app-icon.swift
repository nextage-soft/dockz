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

    // Isometric shipping container: front face with vertical corrugation,
    // lighter top face, shaded right side. Drawn by hand — SF Symbols has
    // boxes, not cargo containers.
    let w = canvas * 0.50      // front face width
    let h = canvas * 0.33      // front face height
    let dx = canvas * 0.095    // isometric depth (right)
    let dy = canvas * 0.068    // isometric depth (up)
    let fx = (canvas - w - dx) / 2
    let fy = (canvas - h - dy) / 2 + canvas * 0.025

    let silhouette = NSBezierPath()
    silhouette.move(to: NSPoint(x: fx, y: fy))
    silhouette.line(to: NSPoint(x: fx + w, y: fy))
    silhouette.line(to: NSPoint(x: fx + w + dx, y: fy + dy))
    silhouette.line(to: NSPoint(x: fx + w + dx, y: fy + h + dy))
    silhouette.line(to: NSPoint(x: fx + dx, y: fy + h + dy))
    silhouette.line(to: NSPoint(x: fx, y: fy + h))
    silhouette.close()

    // Soft drop shadow under the whole container
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = canvas * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.012)
    shadow.set()
    NSColor.white.setFill()
    silhouette.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Top face (brightest)
    let top = NSBezierPath()
    top.move(to: NSPoint(x: fx, y: fy + h))
    top.line(to: NSPoint(x: fx + w, y: fy + h))
    top.line(to: NSPoint(x: fx + w + dx, y: fy + h + dy))
    top.line(to: NSPoint(x: fx + dx, y: fy + h + dy))
    top.close()
    NSColor.white.setFill()
    top.fill()

    // Right side face (dimmed for depth)
    let side = NSBezierPath()
    side.move(to: NSPoint(x: fx + w, y: fy))
    side.line(to: NSPoint(x: fx + w + dx, y: fy + dy))
    side.line(to: NSPoint(x: fx + w + dx, y: fy + h + dy))
    side.line(to: NSPoint(x: fx + w, y: fy + h))
    side.close()
    NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.98, alpha: 1).setFill()
    side.fill()

    // Front face
    let front = NSRect(x: fx, y: fy, width: w, height: h)
    NSColor(calibratedRed: 0.94, green: 0.97, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(rect: front).fill()

    // Corrugation: vertical grooves in the background blue
    let grooves = 6
    let inset = w * 0.075
    let slotHeight = h * 0.74
    let usable = w - 2 * inset
    let slotWidth = usable / (CGFloat(grooves) * 1.9 - 0.9)
    let gap = slotWidth * 0.9
    let groove = NSColor(calibratedRed: 0.13, green: 0.38, blue: 0.82, alpha: 0.85)
    for index in 0..<grooves {
        let slotX = fx + inset + CGFloat(index) * (slotWidth + gap)
        let slot = NSRect(x: slotX, y: fy + (h - slotHeight) / 2,
                          width: slotWidth, height: slotHeight)
        groove.setFill()
        NSBezierPath(roundedRect: slot, xRadius: slotWidth * 0.32, yRadius: slotWidth * 0.32).fill()
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
