import AppKit

/// The menu bar glyph [v4 §2], drawn in code as an 18 × 18 template: a screen (rounded frame, no
/// stand, so it is not macOS's own Displays icon) with the light rising inside it (a half-disc on
/// the frame's inner bottom edge). While a change waits for Keep the light is an outline and the
/// item adds ` Keep?`. Never animated, never red; the menu bar tints it.
enum StatusGlyph {
    static let size = NSSize(width: 18, height: 18)
    /// Frame, unflipped points.
    static let frame = NSRect(x: 2, y: 4.25, width: 14, height: 9.5)
    static let frameRadius: CGFloat = 2.25
    static let lightRadius: CGFloat = 3.25

    static func lineWidth(increaseContrast: Bool) -> CGFloat { increaseContrast ? 2 : 1.5 }

    /// The template image; `increaseContrast` thickens the frame.
    static func image(pending: Bool,
                      increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(pending: pending, increaseContrast: increaseContrast)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = pending ? "Keeplight, keep change?" : "Keeplight"
        return image
    }

    static func draw(pending: Bool, increaseContrast: Bool) {
        NSColor.black.set()
        let line = lineWidth(increaseContrast: increaseContrast)
        let screen = NSBezierPath(roundedRect: frame, xRadius: frameRadius, yRadius: frameRadius)
        screen.lineWidth = line
        screen.stroke()
        // The light: the upper half of a disc centred on the frame's inner bottom edge.
        let center = NSPoint(x: frame.midX, y: frame.minY + line / 2)
        let light = NSBezierPath()
        light.move(to: NSPoint(x: center.x - lightRadius, y: center.y))
        light.appendArc(withCenter: center, radius: lightRadius, startAngle: 180, endAngle: 0, clockwise: true)
        light.close()
        if pending {
            light.lineWidth = 1
            light.stroke()
        } else {
            light.fill()
        }
    }
}
