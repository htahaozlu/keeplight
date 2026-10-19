import AppKit
import QuartzCore

/// The onboarding stage (§4): 480 × 200, r 12, `paper.raised` with a hairline edge (Increase
/// Contrast: 1 pt ink). It never moves; only the scene inside it changes. Scenes attach their root
/// layers to `content` (clipped to the rounded rect); the edge is drawn above them.
///
/// For VoiceOver the stage is one image with the scene's label and a `Replay` action. A click (or
/// Space with Full Keyboard Access) replays the scene. Layers only, no `draw(_:)`.
final class StageView: NSView {
    let content = CALayer()
    private let edge = CALayer()

    var onReplay: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    /// The scene shown (its label is the stage's).
    weak var scene: StageScene? {
        didSet { NSAccessibility.post(element: self, notification: .titleChanged) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for l in [content, edge] {
            l.delegate = NoImplicitActions.shared
            l.cornerRadius = OnboardingTheme.Radius.stage
            l.cornerCurve = .continuous
            layer?.addSublayer(l)
        }
        content.masksToBounds = true
        edge.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        edge.frame = bounds
        CATransaction.commit()
    }

    func apply(_ p: StagePalette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.backgroundColor = p.paperRaised
        edge.borderColor = p.raisedEdge
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onAppearanceChange?()
    }

    // MARK: input

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onReplay?() }

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onReplay?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: OnboardingTheme.Radius.stage, yRadius: OnboardingTheme.Radius.stage).fill()
    }

    // MARK: accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { scene?.accessibilityText }
    override func accessibilityHelp() -> String? { OnboardingCopy.replayHelp }
    override func accessibilityPerformPress() -> Bool {
        onReplay?()
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: OnboardingCopy.replay) { [weak self] in
            self?.onReplay?()
            return true
        }]
    }
}

/// Onboarding progress (§4): N segments of 20 × 3 pt, r 1.5, 6 pt apart; done and current `ink`,
/// next `ink.3` — never red, never dots. One VoiceOver element, `Step 2 of 3`. The colour change
/// belongs to the page transition, so the segments are named layers.
final class ProgressSegments: NSView {
    static let segment = CGSize(width: 20, height: 3)
    static let gap: CGFloat = 6
    static let maxCount = 3
    static func id(_ i: Int) -> LayerID { "progress." + String(i) }

    private let host = CALayer()
    private(set) var segments: [CALayer] = []
    private var palette: StagePalette?

    /// Steps shown (2 or 3).
    var count = 3 {
        didSet {
            guard count != oldValue else { return }
            for (i, s) in segments.enumerated() { s.isHidden = i >= count }
            invalidateIntrinsicContentSize()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// The step shown; set without animation (the transition animates the colours).
    var current = 0 {
        didSet {
            guard current != oldValue else { return }
            applyColors()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        host.delegate = NoImplicitActions.shared
        host.isGeometryFlipped = true
        layer?.addSublayer(host)
        for i in 0..<Self.maxCount {
            let s = CALayer()
            s.delegate = NoImplicitActions.shared
            s.anchorPoint = .zero
            s.bounds = CGRect(origin: .zero, size: Self.segment)
            s.position = CGPoint(x: CGFloat(i) * (Self.segment.width + Self.gap), y: 0)
            s.cornerRadius = Self.segment.height / 2
            host.addSublayer(s)
            segments.append(s)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(count) * Self.segment.width + CGFloat(count - 1) * Self.gap, height: Self.segment.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = CGRect(x: 0, y: ((bounds.height - Self.segment.height) / 2).rounded(), width: bounds.width,
                            height: Self.segment.height)
        CATransaction.commit()
    }

    func apply(_ p: StagePalette) {
        palette = p
        applyColors()
    }

    /// Done and current steps are ink, the rest ink.3.
    func color(_ i: Int, current c: Int) -> CGColor? {
        guard let palette else { return nil }
        return i <= c ? palette.ink : palette.ink3
    }

    var layers: [LayerID: CALayer] {
        Dictionary(uniqueKeysWithValues: segments.enumerated().map { (Self.id($0.offset), $0.element) })
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, s) in segments.enumerated() { s.backgroundColor = color(i, current: current) }
        CATransaction.commit()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { OnboardingCopy.step(current, of: count) }
}
