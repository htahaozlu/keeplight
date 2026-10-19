import AppKit
import QuartzCore

/// Page 3, waiting — **Access** (§4; Nokta's AccessScene): an abstract `Privacy & Security ›
/// Accessibility` list, two placeholder rows and a highlighted Keeplight row whose switch the stage
/// cursor turns on. Drawn from our own shapes — no Apple screenshot, glyph or control.
///
/// Waiting: a 3200 ms loop, ≤ 3 cycles plus the tail; rest = explainT = 1500 (switch on, cursor on
/// it). Granted: the switch stays on and the cursor is gone (`grantedPose`).
final class AccessScene: StageScene {
    enum ID {
        static let cursor: LayerID = "a.cursor", knob: LayerID = "a.knob", fill: LayerID = "a.fill"
    }

    static let panelRect = CGRect(x: 90, y: 18, width: 300, height: 164)
    static let rowYs: [CGFloat] = [54, 94, 134]
    static let rowHeight: CGFloat = 40
    static let track = CGRect(x: 340, y: 106, width: 28, height: 16)
    static let knobOff = CGPoint(x: 348, y: 114), knobOn = CGPoint(x: 360, y: 114)
    static let cursorStart = CGPoint(x: 372, y: 176), cursorOnSwitch = CGPoint(x: 354, y: 114)
    static let loop = 3200.0, explainT = 1500.0

    private let panel = CALayer()
    private let separator = CALayer()
    private var placeholders: [CALayer] = []
    private let highlight = CALayer()
    private var header: CATextLayer!
    private var name: CATextLayer!
    private let markFrame = CAShapeLayer(), markLight = CAShapeLayer()
    private let trackLayer = CALayer(), fill = CALayer(), knob = CALayer()
    private var cursor: CAShapeLayer!

    override var accessibilityText: String { OnboardingCopy.accessLabel }
    override var loops: Int { SceneTimeline.maxLoops }

    override init() {
        super.init()
        let pr = Self.panelRect
        add(panel, frame: pr)
        panel.cornerRadius = OnboardingTheme.Radius.group
        panel.cornerCurve = .continuous
        panel.borderWidth = 1
        header = text(OnboardingCopy.scenePane, role: .caption, origin: CGPoint(x: 104, y: 25), width: pr.width - 28)
        add(separator, frame: CGRect(x: pr.minX, y: 46, width: pr.width, height: 1))
        add(highlight, frame: CGRect(x: pr.minX + 1, y: Self.rowYs[1], width: pr.width - 2, height: Self.rowHeight))
        for y in [Self.rowYs[0], Self.rowYs[2]] {
            let icon = add(CALayer(), frame: CGRect(x: 104, y: y + 10, width: 20, height: 20))
            icon.cornerRadius = 5
            let bar = add(CALayer(), frame: CGRect(x: 134, y: y + 17, width: 80, height: 6))
            bar.cornerRadius = 3
            placeholders += [icon, bar]
        }
        // Keeplight's row: the mark (the menu bar glyph's geometry, ink) and the name.
        let paths = StageMark.paths(size: 20, line: 1.5)
        for l in [markFrame, markLight] { add(l, frame: CGRect(x: 104, y: 104, width: 20, height: 20)) }
        markFrame.path = paths.frame
        markFrame.lineWidth = 1.5
        markFrame.fillColor = nil
        markLight.path = paths.light
        name = text(OnboardingCopy.wordmark, role: .caption, origin: CGPoint(x: 134, y: 107), width: 120)
        // The switch picture: track 28 × 16 r 8 with a 1 pt edge; filled ink when on; knob Ø 12.
        add(trackLayer, frame: Self.track)
        trackLayer.cornerRadius = 8
        trackLayer.borderWidth = 1
        add(fill, ID.fill, frame: Self.track)
        fill.cornerRadius = 8
        add(knob, ID.knob, frame: CGRect(x: Self.knobOff.x - 6, y: Self.knobOff.y - 6, width: 12, height: 12),
            anchor: CGPoint(x: 0.5, y: 0.5))
        knob.cornerRadius = 6
        knob.borderWidth = 1
        cursor = StageCursor.make(in: self, ID.cursor, tip: Self.cursorStart)
    }

    override func apply(_ p: StagePalette) {
        super.apply(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.backgroundColor = p.paper
        panel.borderColor = p.raisedEdge
        separator.backgroundColor = p.hairline
        header.foregroundColor = p.ink2
        highlight.backgroundColor = p.inkHighlight
        for l in placeholders { l.backgroundColor = p.inkWash }
        markFrame.strokeColor = p.ink
        markLight.fillColor = p.ink
        name.foregroundColor = p.ink
        trackLayer.borderColor = p.ink3
        fill.backgroundColor = p.ink
        knob.backgroundColor = p.paperRaised
        knob.borderColor = p.ink3
        StageCursor.apply(p, to: cursor)
        CATransaction.commit()
    }

    private static func s(_ v: Double) -> SceneValue { .scalar(v) }

    /// The cursor appears · moves to the switch · presses · the switch turns on (knob +12, fill) ·
    /// holds (explainT) · the cursor leaves · the switch turns off. pose(0) == pose(3200).
    override var timeline: SceneTimeline {
        SceneTimeline(name: "onb.access", duration: Self.loop, restT: Self.explainT, explainT: Self.explainT, tracks: [
            SceneTrack(ID.cursor, SceneKeyPath.opacity, [SceneKey(0, Self.s(0), .out), SceneKey(150, Self.s(1)),
                                              SceneKey(2400, Self.s(1), .out), SceneKey(2600, Self.s(0))]),
            SceneTrack(ID.cursor, SceneKeyPath.position, [SceneKey(150, .point(Self.cursorStart), .hand),
                                               SceneKey(750, .point(Self.cursorOnSwitch)),
                                               SceneKey(2600, .point(Self.cursorOnSwitch), .step),
                                               SceneKey(Self.loop, .point(Self.cursorStart))]),
            SceneTrack(ID.cursor, "transform.scale", [SceneKey(750, Self.s(1), .out), SceneKey(830, Self.s(0.88), .out),
                                                      SceneKey(910, Self.s(1))]),
            SceneTrack(ID.knob, SceneKeyPath.position, [SceneKey(830, .point(Self.knobOff), .out), SceneKey(1030, .point(Self.knobOn)),
                                             SceneKey(2700, .point(Self.knobOn), .hand), SceneKey(3000, .point(Self.knobOff))]),
            SceneTrack(ID.fill, SceneKeyPath.opacity, [SceneKey(830, Self.s(0), .out), SceneKey(1030, Self.s(1)),
                                            SceneKey(2700, Self.s(1), .hand), SceneKey(3000, Self.s(0))]),
        ])
    }

    /// Access granted: the switch on, no cursor.
    static var grantedPose: ScenePose {
        var p = ScenePose()
        p[ID.cursor, SceneKeyPath.opacity] = s(0)
        p[ID.cursor, SceneKeyPath.position] = .point(cursorOnSwitch)
        p[ID.cursor, "transform.scale"] = s(1)
        p[ID.knob, SceneKeyPath.position] = .point(knobOn)
        p[ID.fill, SceneKeyPath.opacity] = s(1)
        return p
    }
}
