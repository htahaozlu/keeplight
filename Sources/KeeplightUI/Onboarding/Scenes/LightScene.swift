import AppKit
import QuartzCore

/// Page 1 — **Light** (§4): the user's real displays as outlines (≤ 3, 120 × 72, r 6, 1.5 pt) at
/// their arrangement, each with its light (`sun.max`, the ledger's brightness symbol) coming up
/// from dim. 0–240 the outlines fade in from .98 (60 ms stagger), 300–1500 the light α .15 → .85
/// (`glide`), 1500–1740 the names. Plays once (2400); explainT = rest = 2400.
final class LightScene: StageScene {
    struct Screen: Equatable {
        var name: String
        /// Global display bounds (CoreGraphics, y down).
        var bounds: CGRect
    }

    enum ID {
        static func outline(_ i: Int) -> LayerID { "l.outline" + String(i) }
        static func light(_ i: Int) -> LayerID { "l.light" + String(i) }
        static func name(_ i: Int) -> LayerID { "l.name" + String(i) }
    }

    static let outlineSize = CGSize(width: 120, height: 72)
    static let gap: CGFloat = 28
    static let duration = 2400.0
    static let maxScreens = 3

    private(set) var screens: [Screen] = []
    private var outlines: [CAShapeLayer] = []
    private var lights: [SymbolLayer] = []
    private var names: [CATextLayer] = []

    override var accessibilityText: String { OnboardingCopy.lightLabel }

    override init() {
        super.init()
        configure([Screen(name: "", bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))])
    }

    /// Rebuilds the outlines for `screens` (the first three in arrangement order).
    func configure(_ new: [Screen]) {
        let shown = Array(new.prefix(Self.maxScreens))
        guard shown != screens || outlines.isEmpty else { return }
        screens = shown
        for l in outlines { remove(l) }
        for l in names { remove(l) }
        outlines = []
        lights = []
        names = []
        let frames = Self.layout(shown.map(\.bounds))
        for (i, frame) in frames.enumerated() {
            let outline = add(CAShapeLayer(), ID.outline(i), frame: frame, anchor: CGPoint(x: 0.5, y: 0.5))
            outline.path = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size).insetBy(dx: 0.75, dy: 0.75),
                                  cornerWidth: 6, cornerHeight: 6, transform: nil)
            outline.lineWidth = 1.5
            let light = symbol("sun.max", pointSize: 24, center: CGPoint(x: frame.width / 2, y: frame.height / 2),
                               in: outline) { $0.ink }
            register(light, ID.light(i))
            let width: CGFloat = frames.count == 1 ? 300 : Self.outlineSize.width + Self.gap - 4
            let name = text(shown[i].name, ID.name(i), role: .caption,
                            origin: CGPoint(x: (frame.midX - width / 2).rounded(), y: frame.maxY + 10), width: width,
                            alignment: .center)
            outlines.append(outline)
            lights.append(light)
            names.append(name)
        }
        if let palette { apply(palette) }
    }

    /// Outlines left to right in arrangement order, each nudged up or down (≤ 20 pt) by where its
    /// display sits; the group is centred on the stage, names included.
    static func layout(_ bounds: [CGRect]) -> [CGRect] {
        let n = max(1, min(bounds.count, maxScreens))
        let items = bounds.isEmpty ? [CGRect(x: 0, y: 0, width: 1, height: 1)] : Array(bounds.prefix(n))
        let order = items.indices.sorted { (items[$0].midX, items[$0].midY) < (items[$1].midX, items[$1].midY) }
        let widths = items.map(\.width).sorted()
        let k = outlineSize.width / max(widths[widths.count / 2], 1)
        let meanY = items.map(\.midY).reduce(0, +) / CGFloat(items.count)
        let total = CGFloat(n) * outlineSize.width + CGFloat(n - 1) * gap
        let x0 = ((size.width - total) / 2).rounded()
        // Outline 72, 10 to the name, name 14: centred block of 96.
        let y0 = ((size.height - (outlineSize.height + 24)) / 2).rounded()
        var out = Array(repeating: CGRect.zero, count: n)
        for (slot, index) in order.enumerated() {
            let dy = min(max((items[index].midY - meanY) * k, -20), 20).rounded()
            out[index] = CGRect(x: x0 + CGFloat(slot) * (outlineSize.width + gap), y: y0 + dy,
                                width: outlineSize.width, height: outlineSize.height)
        }
        return out
    }

    override func apply(_ p: StagePalette) {
        super.apply(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for o in outlines {
            o.strokeColor = p.ink2
            o.fillColor = p.inkWash
        }
        for t in names { t.foregroundColor = p.ink2 }
        CATransaction.commit()
    }

    private static func s(_ v: Double) -> SceneValue { .scalar(v) }

    override var timeline: SceneTimeline {
        var tracks: [SceneTrack] = []
        for i in outlines.indices {
            let t0 = 60.0 * Double(i)
            tracks.append(SceneTrack(ID.outline(i), SceneKeyPath.opacity, [SceneKey(t0, Self.s(0), .out), SceneKey(t0 + 240, Self.s(1))]))
            tracks.append(SceneTrack(ID.outline(i), "transform.scale", [SceneKey(t0, Self.s(0.98), .out), SceneKey(t0 + 240, Self.s(1))]))
            tracks.append(SceneTrack(ID.light(i), SceneKeyPath.opacity, [SceneKey(300, Self.s(0.15), .glide), SceneKey(1500, Self.s(0.85))]))
            tracks.append(SceneTrack(ID.name(i), SceneKeyPath.opacity, [SceneKey(1500, Self.s(0), .out), SceneKey(1740, Self.s(1))]))
        }
        return SceneTimeline(name: "onb.light", duration: Self.duration, tracks: tracks)
    }
}
