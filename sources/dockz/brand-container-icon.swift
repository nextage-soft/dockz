import AppKit

/// The DockZ mark — a corrugated shipping container — drawn in code so the
/// menu bar icon always matches the bundle icon (see
/// scripts/generate-app-icon.swift, which paints the full-color variant).
enum BrandContainerIcon {
    /// Monochrome template image for the status item. Front view: rounded
    /// outline with vertical corrugation ribs — reads as a container at 18 px.
    static func statusItemImage() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let body = NSRect(x: 1.25, y: 4.5, width: side - 2.5, height: side - 9)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.4
            NSColor.black.setStroke()
            outline.stroke()

            let ribs = 4
            let step = body.width / CGFloat(ribs + 1)
            for index in 1...ribs {
                let x = body.minX + step * CGFloat(index)
                let rib = NSBezierPath()
                rib.move(to: NSPoint(x: x, y: body.minY + 2.2))
                rib.line(to: NSPoint(x: x, y: body.maxY - 2.2))
                rib.lineWidth = 1.4
                rib.lineCapStyle = .round
                rib.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DockZ"
        return image
    }
}
