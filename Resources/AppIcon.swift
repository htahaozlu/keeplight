// Renders the Keeplight app icon at six sizes (16, 32, 128, 256, 512, 1024 px; no duplicate
// representations, macOS scales the rest). Regenerate:
//   swift Resources/AppIcon.swift /tmp/AppIcon.iconset && oxipng -o max --zopfli --strip all -q /tmp/AppIcon.iconset/*.png \
//     && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

// The status glyph's shape, larger: a screen (rounded frame, no stand) with the light rising inside
// it (a half-disc on the frame's inner bottom edge). Ink on a near-black tile, no red: red belongs to
// the Fuse (docs/design/v4-keeplight.md §1–2).
func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    rep.size = NSSize(width: px, height: px)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let k = Double(px) / 1024
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let tile = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)

    // Flat: one solid fill, no gradient, shadow or hairline (they cost bytes and vanish at small sizes).
    NSColor(srgbRed: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x13 / 255.0, alpha: 1).setFill()
    tile.fill()

    // Small sizes get a heavier line so the frame survives at 16 px.
    let line = max((px <= 32 ? 64 : 44) * k, 1)
    let frame = NSRect(x: body.midX - 280 * k, y: body.midY - 170 * k, width: 560 * k, height: 380 * k)
    let ink = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF3 / 255.0, alpha: 1)
    ink.set()
    let screen = NSBezierPath(roundedRect: frame.insetBy(dx: line / 2, dy: line / 2), xRadius: 72 * k, yRadius: 72 * k)
    screen.lineWidth = line
    screen.stroke()
    // On the stroke's centre line, so the half-disc overlaps the frame instead of meeting it at an
    // anti-aliased seam.
    let center = NSPoint(x: frame.midX, y: frame.minY + line / 2)
    let radius = 128 * k
    let light = NSBezierPath()
    light.move(to: NSPoint(x: center.x - radius, y: center.y))
    light.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
    light.close()
    light.fill()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift AppIcon.swift <out.iconset>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
// 16 → 16, 16@2x → 32, 128, 128@2x → 256, 256@2x → 512, 512@2x → 1024 (the master).
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256@2x", 512), ("icon_512x512@2x", 1024)] {
    try render(px: px).write(to: out.appendingPathComponent(name + ".png"))
}
