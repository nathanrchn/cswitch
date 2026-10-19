import AppKit

/// Shared vector artwork for the status item and the app's generated icon.
enum CswitchIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            drawGlyph(in: bounds, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Cswitch · Claude Code accounts"
        return image
    }

    static func drawAppIcon(in bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(scaleByX: bounds.width / 1024, byY: bounds.height / 1024)
        (transform as NSAffineTransform).concat()
        NSColor(srgbRed: 0.77, green: 0.45, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928),
                     xRadius: 212, yRadius: 212).fill()
        drawGlyph(in: NSRect(x: 206, y: 206, width: 612, height: 612),
                  color: NSColor(srgbRed: 1, green: 0.97, blue: 0.91, alpha: 1))
    }

    static func drawGlyph(in bounds: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        var transform = AffineTransform(translationByX: bounds.minX, byY: bounds.minY)
        transform.scale(x: bounds.width / 24, y: bounds.height / 24)
        (transform as NSAffineTransform).concat()
        color.setStroke()
        color.setFill()

        let top = NSBezierPath()
        top.move(to: NSPoint(x: 4.2, y: 13.8))
        top.curve(to: NSPoint(x: 19.6, y: 13.3),
                  controlPoint1: NSPoint(x: 4.2, y: 23.5),
                  controlPoint2: NSPoint(x: 19.6, y: 23.5))
        top.lineWidth = 1.9
        top.lineCapStyle = .round
        top.lineJoinStyle = .round
        top.stroke()
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: 16.8, y: 15.9))
        tip.line(to: NSPoint(x: 19.6, y: 13.1))
        tip.line(to: NSPoint(x: 22.2, y: 15.9))
        tip.lineWidth = 1.9
        tip.lineCapStyle = .round
        tip.lineJoinStyle = .round
        tip.stroke()

        var opposite = AffineTransform(translationByX: 24, byY: 24)
        opposite.scale(x: -1, y: -1)
        top.transform(using: opposite)
        tip.transform(using: opposite)
        top.stroke()
        tip.stroke()

        NSBezierPath(ovalIn: NSRect(x: 10.3, y: 12.7, width: 3.4, height: 3.4)).fill()
        let shoulders = NSBezierPath()
        shoulders.move(to: NSPoint(x: 8.4, y: 8.1))
        shoulders.curve(to: NSPoint(x: 15.6, y: 8.1),
                        controlPoint1: NSPoint(x: 8.4, y: 13),
                        controlPoint2: NSPoint(x: 15.6, y: 13))
        shoulders.close()
        shoulders.fill()
    }
}
