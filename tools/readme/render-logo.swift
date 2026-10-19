import AppKit

// README logo:  swift tools/readme/render-logo.swift   (from the repository root)
//
// Writes docs/images/logo-light.png and docs/images/logo-dark.png at 2x: the app icon beside the
// `Keeplight` wordmark. Transparent background, so it sits on GitHub's light and dark themes.
//
// The icon is drawn here as vectors with the geometry of Resources/AppIcon.swift (1024 canvas:
// tile 824 at 100, radius 185, #111113; screen frame 560 × 380 centred 30 below the middle,
// line 44, radius 72, ink #F5F5F3; the light, a half-disc r 128 on the frame's inner bottom edge),
// so it stays sharp at any size. The wordmark is the onboarding one (OnboardingTheme.swift: SF
// Bold, tracking −0.6 at 40 pt, i.e. −0.015 em). No red: red belongs to the Fuse
// (docs/design/v4-keeplight.md §1). On the dark variant the near-black tile gets the dark
// `hairline` (white α.14) so its edge still reads on a dark page.

let root = FileManager.default.currentDirectoryPath
let tileInk = NSColor(srgbRed: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x13 / 255.0, alpha: 1)   // ink (light)
let lightInk = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF3 / 255.0, alpha: 1)  // ink (dark)

/// The app icon in `rect` (a square standing for AppIcon.swift's 1024 canvas).
func drawIcon(in rect: NSRect, hairline: NSColor?) {
    let k = rect.width / 1024
    let body = NSRect(x: rect.minX + 100 * k, y: rect.minY + 100 * k, width: 824 * k, height: 824 * k)
    let tile = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)
    tileInk.setFill()
    tile.fill()
    if let hairline {
        let edge = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 185 * k - 0.5, yRadius: 185 * k - 0.5)
        edge.lineWidth = 1
        hairline.setStroke()
        edge.stroke()
    }
    let line = 44 * k
    let frame = NSRect(x: body.midX - 280 * k, y: body.midY - 170 * k, width: 560 * k, height: 380 * k)
    lightInk.set()
    let screen = NSBezierPath(roundedRect: frame.insetBy(dx: line / 2, dy: line / 2), xRadius: 72 * k, yRadius: 72 * k)
    screen.lineWidth = line
    screen.stroke()
    let center = NSPoint(x: frame.midX, y: frame.minY + line)
    let radius = 128 * k
    // The half-disc, plus a sliver reaching down into the frame's line (same ink), so the two
    // anti-aliased edges don't leave a seam where the light meets the frame.
    let light = NSBezierPath()
    light.move(to: NSPoint(x: center.x - radius, y: center.y - line / 2))
    light.line(to: NSPoint(x: center.x - radius, y: center.y))
    light.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
    light.line(to: NSPoint(x: center.x + radius, y: center.y - line / 2))
    light.close()
    light.fill()
}

func render(ink: NSColor, hairline: NSColor?, to path: String) {
    let iconSide: CGFloat = 168, spacing: CGFloat = 26, fontSize: CGFloat = 104
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let kern = -0.015 * fontSize
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: kern]
    let word = NSAttributedString(string: "Keeplight", attributes: attrs)
    let textWidth = word.size().width - kern // no tracking after the last letter
    let size = NSSize(width: ceil(iconSide + spacing + textWidth + 8), height: 200)
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    drawIcon(in: NSRect(x: 0, y: (size.height - iconSide) / 2, width: iconSide, height: iconSide), hairline: hairline)

    // Optically centred on the tile: cap height and descender balanced around the middle.
    let baseline = (size.height - font.capHeight) / 2 + 2
    word.draw(at: NSPoint(x: iconSide + spacing, y: baseline + font.descender))

    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do { try data.write(to: URL(fileURLWithPath: path)) } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    print("wrote \(path.replacingOccurrences(of: root + "/", with: "")) (\(rep.pixelsWide)×\(rep.pixelsHigh) px)")
}

try? FileManager.default.createDirectory(atPath: root + "/docs/images", withIntermediateDirectories: true)
render(ink: tileInk, hairline: nil, to: root + "/docs/images/logo-light.png")
render(ink: lightInk, hairline: NSColor(white: 1, alpha: 0.14), to: root + "/docs/images/logo-dark.png")
