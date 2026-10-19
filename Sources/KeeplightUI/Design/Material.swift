import AppKit

/// The panel's one shape: a rounded rectangle with circular corners of `Metrics.panelRadius`.
/// The window's shape (and so its shadow), the opaque fill, the hairline and the clip of the
/// hosted content are all made from `path(in:)`, so no layer can disagree with another at the
/// corners.
struct PanelShape: Equatable {
    var radius: CGFloat = Metrics.panelRadius

    func path(in rect: CGRect) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// The stroke path of a `width` hairline that lies wholly inside `path(in: rect)`.
    func hairlinePath(in rect: CGRect, width: CGFloat) -> CGPath {
        let inset = width / 2
        return PanelShape(radius: max(radius - inset, 0)).path(in: rect.insetBy(dx: inset, dy: inset))
    }

    /// Stretchable mask: the corners are `path(in:)`'s corners, the middle stretches.
    var maskImage: NSImage {
        let edge = radius * 2 + 1
        let shape = self
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(shape.path(in: rect))
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The panel's container [O§3.5]. The window is borderless, so only its content view can tell
/// the window server that the panel is not a rectangle, and AppKit takes that shape (and the
/// shadow) from the `maskImage` of an `NSVisualEffectView` content view and from nothing else:
/// with an `NSGlassEffectView` or a rounded layer as content view the window stays rectangular
/// and its shadow outlines a rectangle around the rounded surface. So every appearance uses one
/// `PanelSurfaceView`: the `.menu` material, or under Reduce Transparency the opaque
/// `surface.base` fill with a hairline. We never draw our own blur.
enum PanelMaterial {
    @MainActor
    static func container(wrapping content: NSView, opaque: Bool = Motion.reduceTransparency) -> PanelSurfaceView {
        PanelSurfaceView(content: content, shape: PanelShape(), opaque: opaque)
    }
}

/// See `PanelMaterial`. Back to front: the material (masked by `maskImage`, which also shapes the
/// window), the opaque fill (Reduce Transparency only), the content clipped to the shape, the
/// hairline (Reduce Transparency only; the menu material draws its own edge).
final class PanelSurfaceView: NSVisualEffectView {
    let shape: PanelShape
    let content: NSView
    let fill: ShapeView
    let clip: ClipView
    let hairline: ShapeView

    init(content: NSView, shape: PanelShape, opaque: Bool) {
        self.shape = shape
        self.content = content
        fill = ShapeView(shape: shape, role: .fill)
        clip = ClipView(shape: shape)
        hairline = ShapeView(shape: shape, role: .hairline)
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 200))
        material = .menu
        blendingMode = .behindWindow
        state = .active
        maskImage = shape.maskImage
        fill.isHidden = !opaque
        hairline.isHidden = !opaque
        for view in [fill, clip, hairline] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        content.frame = clip.bounds
        content.autoresizingMask = [.width, .height]
        clip.addSubview(content)
        matchContentAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var isOpaqueSurface: Bool { !fill.isHidden }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        matchContentAppearance()
    }

    /// Inside a visual effect view AppKit hands subviews the vibrant appearance, which blends text
    /// into the material and takes `inkSecondary` below its measured 4.5:1. The content gets the
    /// plain appearance of the same variant instead, as it had on the glass and opaque surfaces.
    private func matchContentAppearance() {
        let names: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                          .accessibilityHighContrastDarkAqua]
        let name = effectiveAppearance.bestMatch(from: names) ?? .aqua
        if clip.appearance?.name != name { clip.appearance = NSAppearance(named: name) }
    }
}

/// A view whose layer is a `CAShapeLayer` filled or stroked with the panel shape; the color
/// re-resolves on appearance changes.
final class ShapeView: NSView {
    enum Role { case fill, hairline }
    static let hairlineWidth: CGFloat = 0.5

    let shape: PanelShape
    let role: Role

    init(shape: PanelShape, role: Role) {
        self.shape = shape
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var shapeLayer: CAShapeLayer? { layer as? CAShapeLayer }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShape()
    }

    override func layout() {
        super.layout()
        updateShape()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateShape()
        updateColor()
    }

    private func updateShape() {
        guard let layer = shapeLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch role {
        case .fill:
            layer.path = shape.path(in: bounds)
        case .hairline:
            layer.path = shape.hairlinePath(in: bounds, width: Self.hairlineWidth)
            layer.fillColor = nil
            layer.lineWidth = Self.hairlineWidth
        }
        CATransaction.commit()
    }

    private func updateColor() {
        guard let layer = shapeLayer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch role {
            case .fill: layer.fillColor = Palette.surfaceBase.cgColor
            case .hairline: layer.strokeColor = Palette.line.cgColor
            }
        }
    }
}

/// Clips its subviews (the hosted panel content) to the panel shape with a shape-layer mask.
final class ClipView: NSView {
    let shape: PanelShape
    private let mask = CAShapeLayer()

    init(shape: PanelShape) {
        self.shape = shape
        super.init(frame: .zero)
        wantsLayer = true
        mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.mask = mask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var maskPath: CGPath? { mask.path }

    override func layout() {
        super.layout()
        updateMask()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMask()
    }

    private func updateMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        mask.path = shape.path(in: bounds)
        CATransaction.commit()
    }
}
