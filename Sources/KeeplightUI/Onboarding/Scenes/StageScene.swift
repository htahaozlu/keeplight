import AppKit
import QuartzCore

/// A stage scene (§4): named layers under one stage-sized root whose geometry is flipped, so every
/// coordinate is the storyboard's (points from the stage's top left). The root is what a page
/// transition fades and scales; everything inside moves only through the scene's timeline. No
/// `draw(_:)`; text and SF Symbols are the only rasterized contents.
@MainActor
class StageScene {
    nonisolated static let size = CGSize(width: 480, height: 200)

    let root = CALayer()
    private(set) var layers: [LayerID: CALayer] = [:]
    private(set) var palette: StagePalette?
    private(set) var scale: CGFloat = 2

    /// VoiceOver: the stage is an image with this label.
    var accessibilityText: String { "" }

    /// What plays when the scene is on screen and the gate is open.
    var timeline: SceneTimeline { SceneTimeline(name: "scene.still", duration: 0) }
    /// Cycles of `timeline` (1 = once; looping scenes ≤ `SceneTimeline.maxLoops`).
    var loops: Int { 1 }

    init() {
        root.delegate = NoImplicitActions.shared
        root.isGeometryFlipped = true
        root.bounds = CGRect(origin: .zero, size: Self.size)
        root.position = CGPoint(x: Self.size.width / 2, y: Self.size.height / 2) // scales about the centre
    }

    /// Adds `layer` to `parent` (default: the root) at `frame` (parent coordinates; anchor top left
    /// unless given) and names it `id`.
    @discardableResult
    func add<L: CALayer>(_ layer: L, _ id: LayerID? = nil, frame: CGRect, in parent: CALayer? = nil,
                         anchor: CGPoint = .zero) -> L {
        layer.delegate = NoImplicitActions.shared
        layer.anchorPoint = anchor
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.minX + anchor.x * frame.width, y: frame.minY + anchor.y * frame.height)
        layer.contentsScale = scale
        (parent ?? root).addSublayer(layer)
        if let id { layers[id] = layer }
        return layer
    }

    /// Names a layer added without one.
    func register(_ layer: CALayer, _ id: LayerID) { layers[id] = layer }

    /// Removes `layer` and its sublayers from the scene (and their names).
    func remove(_ layer: CALayer) {
        var gone: Set<ObjectIdentifier> = []
        func walk(_ l: CALayer) { gone.insert(ObjectIdentifier(l)); l.sublayers?.forEach(walk) }
        walk(layer)
        layers = layers.filter { !gone.contains(ObjectIdentifier($0.value)) }
        layer.removeFromSuperlayer()
    }

    /// A one-line text layer whose top-left is `origin`.
    func text(_ string: String, _ id: LayerID? = nil, role: OnboardingTheme.Role, origin: CGPoint, width: CGFloat,
              alignment: CATextLayerAlignmentMode = .left, in parent: CALayer? = nil) -> CATextLayer {
        let t = CATextLayer()
        let font = OnboardingTheme.font(role)
        t.string = string
        t.font = font
        t.fontSize = font.pointSize
        t.alignmentMode = alignment
        t.isWrapped = false
        t.truncationMode = .end
        // CATextLayer puts the font's line at the top; centre it in the role's line height.
        let h = OnboardingTheme.lineHeight(role)
        let natural = ceil(font.ascender - font.descender)
        return add(t, id, frame: CGRect(x: origin.x, y: origin.y + ((h - natural) / 2).rounded(), width: width,
                                        height: natural), in: parent)
    }

    /// A layer showing an SF Symbol, tinted on `apply` (`tint` picks the colour from the palette).
    func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, center: CGPoint,
                in parent: CALayer? = nil, tint: @escaping (StagePalette) -> CGColor) -> SymbolLayer {
        let l = SymbolLayer(name: name, pointSize: pointSize, weight: weight, tint: tint)
        let size = l.imageSize
        add(l, frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width,
                             height: size.height), in: parent)
        return l
    }

    /// Every layer of the scene, root included.
    var allLayers: [CALayer] {
        var out: [CALayer] = []
        func walk(_ l: CALayer) { out.append(l); l.sublayers?.forEach(walk) }
        walk(root)
        return out
    }

    func setScale(_ s: CGFloat) {
        guard s != scale else { return }
        scale = s
        for l in allLayers {
            l.contentsScale = s
            (l as? SymbolLayer)?.render(scale: s, palette: palette)
        }
    }

    /// Static colours; subclasses colour their layers and call super.
    func apply(_ p: StagePalette) {
        palette = p
        for l in allLayers { (l as? SymbolLayer)?.render(scale: scale, palette: p) }
    }

    /// No animation anywhere in the scene, `pose` on its layers.
    func show(_ pose: ScenePose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in allLayers { l.removeAllAnimations() }
        ScenePlayer.set(pose, on: layers)
        CATransaction.commit()
    }
}

/// An SF Symbol rasterized into a layer's contents at the layer's scale, in one palette colour.
final class SymbolLayer: CALayer {
    let symbolName: String
    let pointSize: CGFloat
    let weight: NSFont.Weight
    let tint: (StagePalette) -> CGColor

    init(name: String, pointSize: CGFloat, weight: NSFont.Weight, tint: @escaping (StagePalette) -> CGColor) {
        symbolName = name
        self.pointSize = pointSize
        self.weight = weight
        self.tint = tint
        super.init()
        contentsGravity = .resizeAspect
    }

    override init(layer: Any) {
        let other = layer as? SymbolLayer
        symbolName = other?.symbolName ?? ""
        pointSize = other?.pointSize ?? 12
        weight = other?.weight ?? .regular
        tint = other?.tint ?? { $0.ink }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var image: NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    var imageSize: CGSize {
        guard let size = image?.size else { return CGSize(width: pointSize, height: pointSize) }
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    func render(scale: CGFloat, palette: StagePalette?) {
        guard let palette, let image else { return }
        let size = imageSize
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        // Tint: keep the symbol's alpha, fill with the colour.
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(tint(palette))
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        contents = ctx.makeImage()
        contentsScale = scale
    }
}

// MARK: - shared pieces

/// The stage cursor (Nokta's arrow, used only on the Access scene): 12 × 18, tip at (0, 0), `ink`
/// fill with a 1 pt `paper.raised` outline. Not the system cursor.
@MainActor
enum StageCursor {
    static let size = CGSize(width: 12, height: 18)

    static var path: CGPath {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 15), CGPoint(x: 4, y: 11.5), CGPoint(x: 7, y: 18),
                             CGPoint(x: 9.5, y: 17), CGPoint(x: 6.5, y: 10.5), CGPoint(x: 11.5, y: 10.5)])
        p.closeSubpath()
        return p
    }

    static func make(in scene: StageScene, _ id: LayerID, tip: CGPoint) -> CAShapeLayer {
        let c = scene.add(CAShapeLayer(), id, frame: CGRect(origin: tip, size: size))
        c.path = path
        c.lineWidth = 1
        c.lineJoin = .round
        return c
    }

    static func apply(_ p: StagePalette, to c: CAShapeLayer) {
        c.fillColor = p.ink
        c.strokeColor = p.paperRaised
    }
}

/// Keeplight's mark (§2) in a scene: the rounded screen frame with the half-disc of light rising
/// from its inner bottom edge, at any size (18 = the menu bar glyph).
@MainActor
enum StageMark {
    /// Frame and light paths in a box of `size` (the 18 pt glyph's geometry, scaled).
    static func paths(size: CGFloat, line: CGFloat) -> (frame: CGPath, light: CGPath) {
        let k = size / 18
        let frame = CGRect(x: 2 * k, y: 4.25 * k, width: 14 * k, height: 9.5 * k)
        let r = 2.25 * k
        // Flipped geometry: the inner bottom edge is the frame's max y less half the line.
        let edge = frame.maxY - line / 2
        let light = CGMutablePath()
        light.addArc(center: CGPoint(x: frame.midX, y: edge), radius: 3.25 * k, startAngle: .pi, endAngle: 0,
                     clockwise: false)
        light.closeSubpath()
        return (CGPath(roundedRect: frame, cornerWidth: r, cornerHeight: r, transform: nil), light)
    }
}

/// A round dot or ring centred on its position.
@MainActor
enum StageDot {
    static func make(diameter d: CGFloat) -> CALayer {
        let dot = CALayer()
        dot.delegate = NoImplicitActions.shared
        dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        dot.cornerRadius = d / 2
        return dot
    }
}
