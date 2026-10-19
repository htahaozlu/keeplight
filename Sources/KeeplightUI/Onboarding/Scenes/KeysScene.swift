import AppKit
import QuartzCore

/// Page 3, not asked yet — **Keys** (§4): a 48 pt `sun.max` keycap goes down (0–100), a mini
/// brightness OSD rises on the monitor and its level steps up (100–400), the key comes up
/// (900–1000) and the OSD leaves (2400–2560). Loop 3600, ≤ 3 cycles; rest and explainT 400 (key
/// down, OSD up at the new level).
final class KeysScene: StageScene {
    enum ID {
        static let cap: LayerID = "k.cap"
        static let wash: LayerID = "k.wash"
        static let osd: LayerID = "k.osd"
        static let fill: LayerID = "k.fill"
    }

    static let loop = 3600.0, explainT = 400.0
    static let keyFrame = CGRect(x: 94, y: 72, width: 48, height: 48)
    static let screenFrame = CGRect(x: 202, y: 34, width: 184, height: 112)
    static let osdSize = CGSize(width: 116, height: 22)
    static let track = CGRect(x: 32, y: 10, width: 70, height: 2)
    static let from = 0.5, to = 0.625

    private let depth = CALayer(), cap = CALayer(), wash = CALayer()
    private var capSymbol: SymbolLayer!
    private let screen = CAShapeLayer()
    private let osd = CALayer(), trackLayer = CALayer(), fill = CALayer()
    private var osdSymbol: SymbolLayer!
    private var name: CATextLayer!

    override var accessibilityText: String { OnboardingCopy.keysLabel }
    override var loops: Int { SceneTimeline.maxLoops }

    override init() {
        super.init()
        let k = Self.keyFrame
        add(depth, frame: k.offsetBy(dx: 0, dy: 3))
        add(cap, ID.cap, frame: k)
        add(wash, ID.wash, frame: CGRect(origin: .zero, size: k.size), in: cap)
        for l in [depth, cap, wash] {
            l.cornerRadius = 9
            l.cornerCurve = .continuous
        }
        cap.borderWidth = 1
        wash.opacity = 0
        capSymbol = symbol("sun.max", pointSize: 20, center: CGPoint(x: k.width / 2, y: k.height / 2), in: cap) { $0.ink }

        let s = Self.screenFrame
        add(screen, frame: s)
        screen.path = CGPath(roundedRect: CGRect(origin: .zero, size: s.size).insetBy(dx: 0.75, dy: 0.75),
                             cornerWidth: 6, cornerHeight: 6, transform: nil)
        screen.lineWidth = 1.5

        let o = Self.osdSize
        // Where the real OSD sits: low on the screen.
        add(osd, ID.osd, frame: CGRect(x: s.minX + (s.width - o.width) / 2, y: s.maxY - 18 - o.height, width: o.width,
                                       height: o.height))
        osd.cornerRadius = o.height / 2
        osdSymbol = symbol("sun.max", pointSize: 10, center: CGPoint(x: 17, y: o.height / 2), in: osd) { $0.plateInk }
        add(trackLayer, frame: Self.track, in: osd)
        trackLayer.cornerRadius = 1
        add(fill, ID.fill, frame: CGRect(x: Self.track.minX, y: Self.track.minY, width: Self.track.width * Self.from,
                                          height: Self.track.height), in: osd)
        fill.cornerRadius = 1
        osd.opacity = 0
        name = text("", role: .caption, origin: CGPoint(x: s.minX - 20, y: s.maxY + 10), width: s.width + 40,
                    alignment: .center)
    }

    /// The monitor's name under it (one monitor the keys drive), else none.
    func configure(name new: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        name.string = new ?? ""
        CATransaction.commit()
    }

    override func apply(_ p: StagePalette) {
        super.apply(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        depth.backgroundColor = p.ink3
        cap.backgroundColor = p.paper
        cap.borderColor = p.ink3
        wash.backgroundColor = p.inkPressed
        screen.strokeColor = p.ink2
        screen.fillColor = p.inkWash
        osd.backgroundColor = p.plate
        trackLayer.backgroundColor = p.plateTrack
        fill.backgroundColor = p.plateInk
        name.foregroundColor = p.ink2
        CATransaction.commit()
    }

    private static func s(_ v: Double) -> SceneValue { .scalar(v) }
    private static func width(_ level: Double) -> SceneValue {
        .rect(CGRect(x: 0, y: 0, width: track.width * level, height: track.height))
    }

    /// pose(0) == pose(3600): key up, OSD out, the level back where it started.
    override var timeline: SceneTimeline {
        SceneTimeline(name: "onb.keys", duration: Self.loop, restT: Self.explainT, explainT: Self.explainT, tracks: [
            SceneTrack(ID.cap, "transform.translation.y", [SceneKey(0, Self.s(0), .out), SceneKey(100, Self.s(2)),
                                                           SceneKey(900, Self.s(2), .out), SceneKey(1000, Self.s(0))]),
            SceneTrack(ID.wash, SceneKeyPath.opacity, [SceneKey(0, Self.s(0), .out), SceneKey(100, Self.s(1)),
                                            SceneKey(900, Self.s(1), .out), SceneKey(1000, Self.s(0))]),
            SceneTrack(ID.osd, SceneKeyPath.opacity, [SceneKey(100, Self.s(0), .out), SceneKey(400, Self.s(1)),
                                           SceneKey(2400, Self.s(1), .in), SceneKey(2560, Self.s(0))]),
            SceneTrack(ID.fill, SceneKeyPath.bounds, [SceneKey(100, Self.width(Self.from), .glide), SceneKey(400, Self.width(Self.to)),
                                           SceneKey(2560, Self.width(Self.to), .step), SceneKey(Self.loop, Self.width(Self.from))]),
        ])
    }
}
