import AppKit
import Testing
@testable import KeeplightUI

@MainActor
@Suite("Status glyph")
struct GlyphTests {
    /// Alpha at a point (unflipped points) of the glyph drawn at 4×.
    private func alpha(pending: Bool, at point: NSPoint) -> CGFloat {
        let scale: CGFloat = 4
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        StatusGlyph.draw(pending: pending, increaseContrast: false)
        NSGraphicsContext.restoreGraphicsState()
        let x = Int(point.x * scale), y = 71 - Int(point.y * scale)
        return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    @Test func isAnEighteenPointTemplate() {
        let image = StatusGlyph.image(pending: false, increaseContrast: false)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate)
    }

    @Test func idleLightIsFilledAndPendingLightIsAnOutline() {
        // Inside the half-disc, above the frame's bottom line.
        let inside = NSPoint(x: 9, y: StatusGlyph.frame.minY + 2)
        #expect(alpha(pending: false, at: inside) > 0.9)
        #expect(alpha(pending: true, at: inside) < 0.1)
        // The frame is drawn in both; its middle is empty in both.
        let frameLeft = NSPoint(x: StatusGlyph.frame.minX, y: StatusGlyph.frame.midY)
        #expect(alpha(pending: false, at: frameLeft) > 0.5 && alpha(pending: true, at: frameLeft) > 0.5)
        let middle = NSPoint(x: 5, y: StatusGlyph.frame.maxY - 2.5)
        #expect(alpha(pending: false, at: middle) < 0.1)
    }

    @Test func noStandBelowTheScreen() {
        #expect(alpha(pending: false, at: NSPoint(x: 9, y: 2)) < 0.05)
    }
}
