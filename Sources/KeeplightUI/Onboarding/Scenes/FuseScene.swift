import AppKit
import QuartzCore

/// Page 2 — **Fuse** (§4): the Keep card at 0.8 scale, `Keep 3008 × 1692?`, its Fuse burning down
/// like the real card: one dot out every 200 ms from 200 (120 ms fades, from the right), at 3200
/// the card says `Reverted`, it fades out by 4060 and comes back at the loop (4400, ≤ 3 cycles).
/// Rest and explainT 1200: 10 of 15 dots lit. Lit dots are the only red (the signal).
final class FuseScene: StageScene {
    enum ID {
        static let card: LayerID = "f.card"
        static let live: LayerID = "f.live"
        static let resolved: LayerID = "f.resolved"
        static func dot(_ i: Int) -> LayerID { "f.dot" + String(i) }
    }

    static let count = 15
    static let loop = 4400.0, explainT = 1200.0
    static let cardSize = CGSize(width: 340, height: 132)
    static let cardScale = 0.8
    static let dot: CGFloat = 8, pitch: CGFloat = 18

    /// When dot `i` (0 = leftmost) starts to go out.
    static func outTime(_ i: Int) -> Double { 200 + 200 * Double(count - 1 - i) }

    private let card = CALayer()
    private let live = CALayer()
    private let resolved = CALayer()
    private var title: CATextLayer!
    private var resolvedTitle: CATextLayer!
    private var outlines: [CAShapeLayer] = []
    private var fills: [CAShapeLayer] = []
    private let revert = CALayer(), keep = CALayer()
    private var revertText: CATextLayer!, keepText: CATextLayer!

    override var accessibilityText: String { OnboardingCopy.fuseLabel }
    override var loops: Int { SceneTimeline.maxLoops }

    override init() {
        super.init()
        let size = Self.cardSize
        add(card, ID.card, frame: CGRect(x: (Self.size.width - size.width) / 2, y: (Self.size.height - size.height) / 2,
                                         width: size.width, height: size.height), anchor: CGPoint(x: 0.5, y: 0.5))
        card.cornerRadius = 18
        card.cornerCurve = .continuous
        card.setValue(Self.cardScale, forKeyPath: "transform.scale")
        let bounds = CGRect(origin: .zero, size: size)
        add(live, ID.live, frame: bounds, in: card)
        add(resolved, ID.resolved, frame: bounds, in: card)

        title = text(OnboardingCopy.sceneKeepTitle, role: .plate, origin: CGPoint(x: 0, y: 24), width: size.width,
                     alignment: .center, in: live)
        let fuseWidth = CGFloat(Self.count - 1) * Self.pitch + Self.dot
        let x0 = ((size.width - fuseWidth) / 2).rounded()
        let fill = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: Self.dot, height: Self.dot), transform: nil)
        let ring = CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: Self.dot - 1, height: Self.dot - 1), transform: nil)
        for i in 0..<Self.count {
            let frame = CGRect(x: x0 + CGFloat(i) * Self.pitch, y: 58, width: Self.dot, height: Self.dot)
            let o = add(CAShapeLayer(), frame: frame, in: live)
            o.path = ring
            o.fillColor = nil
            o.lineWidth = 1
            let f = add(CAShapeLayer(), ID.dot(i), frame: frame, in: live)
            f.path = fill
            outlines.append(o)
            fills.append(f)
        }
        let button = CGSize(width: 96, height: 28)
        let bx = ((size.width - 2 * button.width - 12) / 2).rounded()
        for (layer, x) in [(revert, bx), (keep, bx + button.width + 12)] {
            add(layer, frame: CGRect(x: x, y: 80, width: button.width, height: button.height), in: live)
            layer.cornerRadius = 8
            layer.cornerCurve = .continuous
        }
        revertText = text(OnboardingCopy.sceneRevert, role: .body, origin: CGPoint(x: 0, y: 6), width: button.width,
                          alignment: .center, in: revert)
        keepText = text(OnboardingCopy.sceneKeep, role: .body, origin: CGPoint(x: 0, y: 6), width: button.width,
                        alignment: .center, in: keep)
        keepText.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        resolvedTitle = text(OnboardingCopy.sceneReverted, role: .plate, origin: CGPoint(x: 0, y: 36), width: size.width,
                             alignment: .center, in: resolved)
        _ = symbol("arrow.uturn.backward", pointSize: 20, weight: .semibold, center: CGPoint(x: size.width / 2, y: 82),
                   in: resolved) { $0.plateInk }
        resolved.opacity = 0
    }

    override func apply(_ p: StagePalette) {
        super.apply(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.backgroundColor = p.plate
        title.foregroundColor = p.plateInk
        resolvedTitle.foregroundColor = p.plateInk
        for o in outlines { o.strokeColor = p.plateSpent }
        for f in fills { f.fillColor = p.plateSignal }
        revert.backgroundColor = p.plateButton
        revertText.foregroundColor = p.plateInk
        keep.backgroundColor = p.plateInk
        keepText.foregroundColor = CGColor(gray: 0, alpha: 1)
        CATransaction.commit()
    }

    private static func s(_ v: Double) -> SceneValue { .scalar(v) }

    /// pose(0) == pose(4400): the card is out, every dot lit, the question up.
    override var timeline: SceneTimeline {
        let k = Self.cardScale
        var tracks = [
            SceneTrack(ID.card, SceneKeyPath.opacity, [SceneKey(0, Self.s(0), .out), SceneKey(180, Self.s(1)),
                                            SceneKey(3900, Self.s(1), .in), SceneKey(4060, Self.s(0))]),
            SceneTrack(ID.card, "transform.scale", [SceneKey(0, Self.s(0.96 * k), .out), SceneKey(180, Self.s(k)),
                                                    SceneKey(4060, Self.s(k), .step), SceneKey(Self.loop, Self.s(0.96 * k))]),
            SceneTrack(ID.live, SceneKeyPath.opacity, [SceneKey(3200, Self.s(1), .in), SceneKey(3320, Self.s(0)),
                                            SceneKey(4060, Self.s(0), .step), SceneKey(Self.loop, Self.s(1))]),
            SceneTrack(ID.resolved, SceneKeyPath.opacity, [SceneKey(3260, Self.s(0), .out), SceneKey(3420, Self.s(1)),
                                                SceneKey(4060, Self.s(1), .step), SceneKey(Self.loop, Self.s(0))]),
        ]
        for i in 0..<Self.count {
            let t = Self.outTime(i)
            tracks.append(SceneTrack(ID.dot(i), SceneKeyPath.opacity, [SceneKey(t, Self.s(1), .out), SceneKey(t + 120, Self.s(0)),
                                                            SceneKey(4060, Self.s(0), .step), SceneKey(Self.loop, Self.s(1))]))
        }
        return SceneTimeline(name: "onb.fuse", duration: Self.loop, restT: Self.explainT, explainT: Self.explainT,
                             tracks: tracks)
    }
}
