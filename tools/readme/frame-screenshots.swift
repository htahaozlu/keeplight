import AppKit
import ImageIO
import UniformTypeIdentifiers

// README screenshots:  scripts/render.sh && swift tools/readme/frame-screenshots.swift [RENDER_DIR]
//
// Takes the offscreen renders of scripts/render.sh (default RENDER_DIR: .build/render; 2×, light and
// dark, real views on fake displays) and writes docs/images/app/:
//   - the panel (1 and 3 displays) and the brightness-key OSD on a rounded mat of the render's own
//     plain-desktop backdrop, 8 pt wider than the render's 16 pt margin;
//   - windows (onboarding pages, Settings tabs; content view only, no title bar or toolbar)
//     with rounded corners, a hairline and a soft shadow on the same mat;
//   - keep-card-<look>.gif: the Keep card counting down at 4× speed and saying `Reverted`. Each
//     frame is built from real pixels: the `keep-mode-15` render (every dot lit) and `keep-mode-00`
//     (every dot spent) differ only inside the 15 dot squares (checked, else the script fails), so
//     a frame with n dots lit is keep-mode-00 with the first n squares taken from keep-mode-15; the
//     composite for 10 dots must match the `keep-mode-10` render (checked too). GIF has no partial
//     transparency, so the corners outside the mat are GitHub's page colour.
// Nothing here launches the app or touches a display; it only reads PNGs and writes images.

let fm = FileManager.default
let root = fm.currentDirectoryPath
let renderDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : root + "/.build/render"
let outDir = root + "/docs/images/app"
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
var failures: [String] = []

func fail(_ message: String) {
    FileHandle.standardError.write(Data("frame-screenshots: \(message)\n".utf8))
    failures.append(message)
}

func load(_ name: String) -> CGImage? {
    let path = "\(renderDir)/\(name).png"
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("missing \(path) (run scripts/render.sh first)")
        return nil
    }
    return image
}

func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// RGBA bytes of `image`, drawn into an sRGB bitmap of its own size.
func pixels(_ image: CGImage) -> [UInt8] {
    let ctx = context(image.width, image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * image.height)
    var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
    for y in 0..<image.height {
        for x in 0..<(image.width * 4) { out[y * image.width * 4 + x] = data[y * ctx.bytesPerRow + x] }
    }
    return out
}

func image(from bytes: [UInt8], width: Int, height: Int) -> CGImage {
    let ctx = context(width, height)
    let data = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
    for y in 0..<height {
        for x in 0..<(width * 4) { data[y * ctx.bytesPerRow + x] = bytes[y * width * 4 + x] }
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return fail("cannot write \(name)") }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fail("cannot write \(name)") }
    print("wrote docs/images/app/\(name).png (\(image.width)×\(image.height) px)")
}

/// The render's backdrop (a plain desktop), read from its top-left pixel.
func backdrop(of image: CGImage) -> CGColor {
    let p = pixels(image)
    return CGColor(colorSpace: srgb, components: [CGFloat(p[0]) / 255, CGFloat(p[1]) / 255, CGFloat(p[2]) / 255, 1])!
}

let pt: CGFloat = 2            // the renders are 2×
let matRadius = 22 * pt

/// A panel or an overlay render (16 pt backdrop margin already) on a rounded mat 8 pt wider.
func matted(_ render: CGImage, pageColor: CGColor? = nil) -> CGImage {
    let pad = Int(8 * pt)
    let w = render.width + 2 * pad, h = render.height + 2 * pad
    let ctx = context(w, h)
    let bounds = CGRect(x: 0, y: 0, width: w, height: h)
    if let pageColor { ctx.setFillColor(pageColor); ctx.fill(bounds) }
    ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: matRadius, cornerHeight: matRadius, transform: nil))
    ctx.clip()
    ctx.setFillColor(backdrop(of: render))
    ctx.fill(bounds)
    ctx.draw(render, in: CGRect(x: pad, y: pad, width: render.width, height: render.height))
    return ctx.makeImage()!
}

/// A window's content render on the mat: rounded corners, hairline, soft shadow.
func windowed(_ render: CGImage, desk: CGColor, dark: Bool) -> CGImage {
    let pad = Int(24 * pt), radius = 14 * pt
    let w = render.width + 2 * pad, h = render.height + 2 * pad
    let ctx = context(w, h)
    let bounds = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: matRadius, cornerHeight: matRadius, transform: nil))
    ctx.clip()
    ctx.setFillColor(desk)
    ctx.fill(bounds)
    let frame = CGRect(x: pad, y: pad, width: render.width, height: render.height)
    let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * pt), blur: 18 * pt,
                  color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.22))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: dark ? 0.1 : 0.97, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(render, in: frame)
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
    ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.12))
    ctx.setLineWidth(1)
    ctx.strokePath()
    return ctx.makeImage()!
}

let looks = ["light", "dark"]

// Panels and overlays.
let matJobs: [(source: String, name: String)] = [
    ("panel-1-display", "panel-1-display"), ("panel-3-displays", "panel-3-displays"), ("osd-075", "osd"),
]
// Windows: onboarding pages and Settings tabs.
let windowJobs: [(source: String, name: String)] = [
    ("onboarding-welcome-3", "onboarding-1"), ("onboarding-keep", "onboarding-2"),
    ("onboarding-keys-not-asked", "onboarding-3"),
    ("settings-general-keys-on", "settings-general"), ("settings-displays-ddc", "settings-displays"),
    ("settings-about", "settings-about"),
]

for look in looks {
    guard let reference = load("keep-mode-15--\(look)") else { continue }
    let desk = backdrop(of: reference)
    for job in matJobs {
        if let render = load("\(job.source)--\(look)") { writePNG(matted(render), "\(job.name)-\(look)") }
    }
    for job in windowJobs {
        if let render = load("\(job.source)--\(look)") { writePNG(windowed(render, desk: desk, dark: look == "dark"), "\(job.name)-\(look)") }
    }
}

// MARK: Keep card GIF

/// The 15 dot squares (px, top-left origin) inside a Keep card render: card at the 16 pt margin, dot
/// centres at x = 44 + 18 i, y = 61.5 pt (Fuse: 8 pt dots, pitch 18, KeepCard.swift layout).
func dotSquares(height: Int) -> [(x: Int, y: Int, side: Int)] {
    (0..<15).map { i in
        let cx = Int((16 + 44 + 18 * CGFloat(i)) * pt), cy = Int((16 + 61.5) * pt)
        return (cx - 10, cy - 10, 20)
    }
}

func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
    zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
}

func writeGIF(_ frames: [(CGImage, Double)], _ name: String) {
    let url = URL(fileURLWithPath: "\(outDir)/\(name).gif")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return fail("cannot write \(name).gif") }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (frame, delay) in frames {
        CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                                                kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
    }
    if !CGImageDestinationFinalize(dest) { return fail("cannot write \(name).gif") }
    let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("wrote docs/images/app/\(name).gif (\(frames.count) frames, \(size / 1024) kB)")
}

let pageColors = ["light": CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),                       // github.com light
                  "dark": CGColor(srgbRed: 0x0D / 255.0, green: 0x11 / 255.0, blue: 0x17 / 255.0, alpha: 1)]  // github.com dark

for look in looks {
    guard let all = load("keep-mode-15--\(look)"), let none = load("keep-mode-00--\(look)"),
          let ten = load("keep-mode-10--\(look)"), let reverted = load("keep-reverted--\(look)") else { continue }
    let w = all.width, h = all.height
    guard none.width == w, none.height == h, ten.width == w, reverted.width == w else { fail("keep renders differ in size"); continue }
    let lit = pixels(all), spent = pixels(none), real10 = pixels(ten)
    let squares = dotSquares(height: h)
    // Which dot square each pixel is in (-1: none).
    var dotOf = [Int](repeating: -1, count: w * h)
    for (index, square) in squares.enumerated() {
        for y in square.y..<(square.y + square.side) {
            for x in square.x..<(square.x + square.side) { dotOf[y * w + x] = index }
        }
    }

    // The two renders must differ only inside the dot squares.
    var outside = 0
    for p in 0..<(w * h) where dotOf[p] < 0 {
        for c in 0..<4 { outside = max(outside, abs(Int(lit[p * 4 + c]) - Int(spent[p * 4 + c]))) }
    }
    if outside > 2 { fail("\(look): keep-mode-15 and keep-mode-00 differ outside the dot squares (max Δ \(outside))") }

    func composite(_ n: Int) -> [UInt8] {
        var out = spent
        for p in 0..<(w * h) where dotOf[p] >= 0 && dotOf[p] < n {
            for c in 0..<4 { out[p * 4 + c] = lit[p * 4 + c] }
        }
        return out
    }
    let delta10 = maxDifference(composite(10), real10)
    if delta10 > 2 { fail("\(look): composite with 10 dots lit differs from keep-mode-10 (max Δ \(delta10))") }

    let page = pageColors[look]!
    func frame(_ bytes: [UInt8]) -> CGImage { matted(image(from: bytes, width: w, height: h), pageColor: page) }
    // An empty desk: the card's backdrop everywhere (its top-left pixel).
    let empty = [UInt8](repeating: 0, count: w * h * 4).enumerated().map { spent[$0.offset % 4] }
    func blend(_ a: [UInt8], _ b: [UInt8], _ t: Double) -> [UInt8] {
        zip(a, b).map { UInt8((Double($0.0) * (1 - t) + Double($0.1) * t).rounded()) }
    }

    var frames: [(CGImage, Double)] = []
    let full = composite(15)
    for t in [0.33, 0.66] { frames.append((frame(blend(empty, full, t)), 0.04)) }   // card in (180 ms in the app)
    frames.append((frame(full), 0.6))
    for n in stride(from: 14, through: 0, by: -1) { frames.append((frame(composite(n)), 0.25)) }  // 1 dot / s in the app
    let revertedBytes = pixels(reverted)
    frames.append((frame(revertedBytes), 0.9))                                       // `Reverted`: 700 ms hold
    for t in [0.33, 0.66] { frames.append((frame(blend(revertedBytes, empty, t)), 0.04)) }
    frames.append((frame(empty), 0.5))
    writeGIF(frames, "keep-card-\(look)")
}

if !failures.isEmpty {
    FileHandle.standardError.write(Data("frame-screenshots: \(failures.count) problem(s)\n".utf8))
    exit(1)
}
