import AppKit
import QuartzCore

/// Onboarding layout (§4), points from the window's top left: the stage at (40, 40, 480, 200); the
/// text column 480 wide at x 40, title at y 264, body at y 304, control rows below; the bottom bar
/// 64 high with the progress left and the buttons right (≥ 76 wide, 12 apart).
enum OnboardingMetrics {
    static let size = CGSize(width: 560, height: 440)
    static let stage = CGRect(origin: CGPoint(x: 40, y: 40), size: StageScene.size)
    static let columnX: CGFloat = 40
    static let columnWidth: CGFloat = 480
    /// Top of the text column; titles sit 8 lower (y 264).
    static let pageTop: CGFloat = 256
    static let barHeight: CGFloat = 64
    static let pageHeight: CGFloat = size.height - barHeight - pageTop
    static let buttonMinWidth: CGFloat = 76
    static let buttonGap: CGFloat = 12

    // In page coordinates (page top = 256).
    static let titleY: CGFloat = 8
    static let bodyY: CGFloat = 48
    static let calloutY: CGFloat = 71
    static let switchY: CGFloat = 93
}

/// The window's content: `paper` ground (a layer colour), flipped like the layout.
class OnboardingContentView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        layer?.backgroundColor = OnboardingTheme.value(.paper, OnboardingTheme.variant(for: effectiveAppearance)).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A leaf view that only hosts layers; `root` is flipped and view-sized. Never hit, never an
/// accessibility element.
final class LayerView: NSView {
    let root = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        root.delegate = NoImplicitActions.shared
        root.isGeometryFlipped = true
        layer?.addSublayer(root)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Labels in the onboarding's type roles.
@MainActor
enum OnboardingText {
    static func label(_ text: String, role: OnboardingTheme.Role, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: NSAttributedString(string: text,
                                                                              attributes: OnboardingTheme.attributes(role, color: color)))
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingTail
        field.wantsLayer = true
        return field
    }

    static func set(_ field: NSTextField, _ text: String, role: OnboardingTheme.Role, color: NSColor) {
        field.attributedStringValue = NSAttributedString(string: text, attributes: OnboardingTheme.attributes(role, color: color))
    }

    /// `field` at `origin`, as wide as its text (at most `maxWidth`), one line high.
    static func place(_ field: NSTextField, at origin: CGPoint, role: OnboardingTheme.Role,
                      maxWidth: CGFloat = OnboardingMetrics.columnWidth) {
        let w = min(maxWidth, ceil(field.cell?.cellSize.width ?? field.intrinsicContentSize.width))
        field.frame = CGRect(x: origin.x, y: origin.y, width: w, height: OnboardingTheme.lineHeight(role))
    }
}

/// VoiceOver announcement and focus.
@MainActor
enum OnboardingSpeech {
    static func announce(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    static func focus(_ element: Any) {
        NSAccessibility.post(element: element, notification: .layoutChanged, userInfo: [.uiElements: [element]])
    }
}

// MARK: - pages

/// One page's text column: 480 wide, top at y 256, laid out by frame (the window has one size).
class OnboardingPage: NSView {
    override var isFlipped: Bool { true }
    var titleField: NSTextField? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ p: StagePalette) {}
}

/// Page 1: the wordmark and one sentence.
final class WelcomePage: OnboardingPage {
    let wordmark = OnboardingText.label(OnboardingCopy.wordmark, role: .wordmark, color: OnboardingTheme.dynamic(.ink))
    private let body = OnboardingText.label(OnboardingCopy.welcomeLine, role: .body, color: Palette.inkSecondary)

    override var titleField: NSTextField? { wordmark }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for v in [wordmark, body] { addSubview(v) }
        wordmark.setAccessibilityRole(.staticText)
        OnboardingText.place(wordmark, at: CGPoint(x: 0, y: 0), role: .wordmark)
        OnboardingText.place(body, at: CGPoint(x: 0, y: OnboardingMetrics.bodyY + 2), role: .body)
    }
}

/// The `Open at login` row: label, then the switch (on the last page).
final class LoginRow: NSView {
    let toggle = NSSwitch()
    private let label = OnboardingText.label(OnboardingCopy.openAtLogin, role: .body, color: .labelColor)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toggle.controlSize = .small
        toggle.setAccessibilityLabel(OnboardingCopy.openAtLogin)
        label.setAccessibilityElement(false)
        addSubview(label)
        addSubview(toggle)
        OnboardingText.place(label, at: CGPoint(x: 0, y: ((frameRect.height - 16) / 2).rounded()), role: .body)
        let size = toggle.fittingSize
        toggle.frame = CGRect(x: label.frame.maxX + 10, y: ((frameRect.height - size.height) / 2).rounded(),
                              width: size.width, height: size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The switch and its label, as wide as they are.
    var contentWidth: CGFloat { toggle.frame.maxX }

    /// The label toggles too: the whole row (24 high) is the switch's target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let local = superview.map({ convert(point, from: $0) }),
              local.x <= contentWidth, bounds.contains(local) else { return nil }
        return toggle.frame.contains(local) ? toggle : self
    }

    override func mouseDown(with event: NSEvent) {
        toggle.state = toggle.state == .on ? .off : .on
        if let action = toggle.action { NSApp.sendAction(action, to: toggle.target, from: toggle) }
    }
}

/// Page 2: `Changes wait for Keep`, the promise, the rescue chord, and (when last) `Open at login`.
final class KeepPage: OnboardingPage {
    private let title = OnboardingText.label(OnboardingCopy.keepTitle, role: .title, color: OnboardingTheme.dynamic(.ink))
    private let body = OnboardingText.label(OnboardingCopy.keepLine, role: .body, color: Palette.inkSecondary)
    private let rescue = OnboardingText.label(OnboardingCopy.rescueLine, role: .callout, color: Palette.inkSecondary)
    let login = LoginRow(frame: CGRect(x: 0, y: OnboardingMetrics.switchY, width: 200, height: 24))

    override var titleField: NSTextField? { title }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for v in [title, body, rescue, login] as [NSView] { addSubview(v) }
        title.setAccessibilityRole(.staticText)
        OnboardingText.place(title, at: CGPoint(x: 0, y: OnboardingMetrics.titleY), role: .title)
        OnboardingText.place(body, at: CGPoint(x: 0, y: OnboardingMetrics.bodyY), role: .body)
        OnboardingText.place(rescue, at: CGPoint(x: 0, y: OnboardingMetrics.calloutY), role: .callout)
    }

    /// The login switch shows only when this is the last page.
    func update(isLast: Bool) { login.isHidden = !isLast }
}

/// Page 3: `Brightness keys`, the sentence naming the monitor, and the permission row:
/// notAsked — the one-line callout; waiting — ○ `Waiting for permission…` and `Not working?`;
/// granted — ● `Brightness keys are on.` The ring fills when access arrives (`grantTimeline`).
final class KeysPage: OnboardingPage {
    enum ID {
        static let ask: LayerID = "p3.ask", waitRow: LayerID = "p3.wait", ring: LayerID = "p3.ring"
        static let fill: LayerID = "p3.fill", waitText: LayerID = "p3.waitText", onText: LayerID = "p3.onText"
        static let help: LayerID = "p3.help"
    }

    enum Shown: Equatable { case notAsked, waiting, granted }

    private let title = OnboardingText.label(OnboardingCopy.keysTitle, role: .title, color: OnboardingTheme.dynamic(.ink))
    private let body = OnboardingText.label("", role: .body, color: Palette.inkSecondary)
    private let ask = OnboardingText.label(OnboardingCopy.askOnce, role: .callout, color: Palette.inkSecondary)
    /// ○ / ● and the two status texts: one VoiceOver element.
    let status = NSView()
    private let dotView = LayerView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    private(set) var ring: CALayer!
    private(set) var fill: CALayer!
    private let waitText = OnboardingText.label(OnboardingCopy.waiting, role: .callout, color: Palette.inkSecondary)
    private let onText = OnboardingText.label(OnboardingCopy.keysOn, role: .callout, color: .labelColor)
    let help = NSButton(title: OnboardingCopy.notWorking, target: nil, action: nil)
    let login = LoginRow(frame: CGRect(x: 0, y: OnboardingMetrics.switchY, width: 200, height: 24))
    private var popover: NSPopover?
    private(set) var shown = Shown.notAsked

    override var titleField: NSTextField? { title }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.setAccessibilityRole(.staticText)
        OnboardingText.place(title, at: CGPoint(x: 0, y: OnboardingMetrics.titleY), role: .title)
        OnboardingText.place(ask, at: CGPoint(x: 0, y: OnboardingMetrics.calloutY), role: .callout)

        let rowHeight: CGFloat = 24
        status.frame = CGRect(x: 0, y: OnboardingMetrics.calloutY - 5, width: 300, height: rowHeight)
        status.wantsLayer = true
        dotView.frame = CGRect(x: 0, y: 6, width: 12, height: 12)
        dotView.layoutSubtreeIfNeeded()
        ring = StageDot.make(diameter: 8)
        ring.position = CGPoint(x: 6, y: 6)
        ring.borderWidth = 1
        fill = StageDot.make(diameter: 8)
        fill.position = CGPoint(x: 6, y: 6)
        dotView.root.addSublayer(ring)
        dotView.root.addSublayer(fill)
        OnboardingText.place(waitText, at: CGPoint(x: 18, y: 5), role: .callout)
        OnboardingText.place(onText, at: CGPoint(x: 18, y: 5), role: .callout)
        for v in [dotView, waitText, onText] { status.addSubview(v) }
        waitText.setAccessibilityElement(false)
        onText.setAccessibilityElement(false)
        status.setAccessibilityElement(true)
        status.setAccessibilityRole(.staticText)

        help.isBordered = false
        help.font = OnboardingTheme.font(.callout)
        help.contentTintColor = Palette.inkSecondary
        help.target = self
        help.action = #selector(showFix(_:))
        help.sizeToFit()
        let hw = max(ceil(help.frame.width) + 8, 76)
        help.frame = CGRect(x: OnboardingMetrics.columnWidth - hw, y: OnboardingMetrics.calloutY - 5, width: hw, height: rowHeight)
        help.alignment = .right
        for v in [title, body, ask, status, help, login] as [NSView] { addSubview(v) }
        show(.notAsked)
    }

    func update(names: [String], isLast: Bool) {
        OnboardingText.set(body, OnboardingCopy.keysLine(names: names), role: .body, color: Palette.inkSecondary)
        OnboardingText.place(body, at: CGPoint(x: 0, y: OnboardingMetrics.bodyY), role: .body)
        login.isHidden = !isLast
    }

    override func apply(_ p: StagePalette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.borderColor = p.ink
        ring.backgroundColor = nil
        fill.backgroundColor = p.ink
        CATransaction.commit()
    }

    /// Layers the state change animates (`OnboardingTimelines.keysState`).
    var stateLayers: [LayerID: CALayer] {
        var out: [LayerID: CALayer] = [:]
        out[ID.ask] = ask.layer
        out[ID.waitRow] = status.layer
        out[ID.ring] = ring
        out[ID.fill] = fill
        out[ID.waitText] = waitText.layer
        out[ID.onText] = onText.layer
        out[ID.help] = help.layer
        return out
    }

    /// The static picture of `state` (also what every state animation ends on).
    func show(_ state: Shown) {
        shown = state
        let waiting = state == .waiting, granted = state == .granted
        ask.isHidden = state != .notAsked
        status.isHidden = state == .notAsked
        help.isHidden = !waiting
        help.isEnabled = waiting
        waitText.isHidden = !waiting
        onText.isHidden = !granted
        status.setAccessibilityLabel(granted ? OnboardingCopy.keysOn : OnboardingCopy.waiting)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in stateLayers.values {
            l.removeAllAnimations()
            l.opacity = 1
        }
        fill.setValue(1, forKeyPath: "transform.scale")
        fill.opacity = granted ? 1 : 0
        CATransaction.commit()
        if !waiting { popover?.close() }
    }

    /// Before an animated change: every layer the change touches is in the tree.
    func prepare(from old: Shown, to new: Shown) {
        let involved: Set<Shown> = [old, new]
        ask.isHidden = !involved.contains(.notAsked)
        status.isHidden = !(involved.contains(.waiting) || involved.contains(.granted))
        help.isHidden = !involved.contains(.waiting)
        waitText.isHidden = !involved.contains(.waiting)
        onText.isHidden = !involved.contains(.granted)
        help.isEnabled = new == .waiting
        shown = new
        status.setAccessibilityLabel(new == .granted ? OnboardingCopy.keysOn : OnboardingCopy.waiting)
    }

    @objc private func showFix(_ sender: NSButton) {
        let text = OnboardingText.label(OnboardingCopy.fix, role: .body, color: .labelColor)
        let pad: CGFloat = 12
        let size = CGSize(width: ceil(text.intrinsicContentSize.width), height: 16)
        text.frame = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: size.width + 2 * pad, height: size.height + 2 * pad))
        container.addSubview(text)
        let vc = NSViewController()
        vc.view = container
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        popover = p
        OnboardingSpeech.announce(OnboardingCopy.fix)
    }
}
