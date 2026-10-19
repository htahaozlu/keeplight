import AppKit
import QuartzCore
import SwiftUI

/// The Fuse's pure clock: how many of `count` dots are lit `elapsed` seconds into `total`.
enum FuseClock {
    /// `ceil(count × (1 − elapsed / total))`, clamped to 0...count.
    static func lit(elapsed: TimeInterval, total: TimeInterval, count: Int = Metrics.fuseCount) -> Int {
        guard total > 0 else { return 0 }
        let value = (Double(count) * (1 - elapsed / total)).rounded(.up)
        return min(max(Int(value), 0), count)
    }

    /// When the dot at `index` (0 = leftmost) goes out. Dots go out from the right: the rightmost
    /// after the first `total / count`, the leftmost at `total`.
    static func flipTime(index: Int, total: TimeInterval, count: Int = Metrics.fuseCount) -> TimeInterval {
        total * Double(count - index) / Double(count)
    }
}

/// The Fuse: `count` dots (8 pt, pitch 18) on the always-dark cards (Keep card, rescue HUD). Lit =
/// filled signal; spent = 1 pt outline. The dot that goes out fades over `Timeline.fuseTick`; there
/// is no timer here, `lit` is the input. (Onboarding draws its own Fuse as a scene.)
struct Fuse: View {
    var lit: Int
    var count = Metrics.fuseCount

    var body: some View {
        FuseRepresentable(lit: min(max(lit, 0), count), count: count)
            .frame(width: FuseLayerView.width(count: count), height: Metrics.fuseDot)
            .accessibilityElement()
            .accessibilityLabel(Self.label(lit: lit, count: count))
    }

    /// Dots, not seconds: a dot stands for a different span on each surface, so the surface that
    /// knows the time (Keep card, rescue HUD) speaks it and hides this label.
    static func label(lit: Int, count: Int) -> String { "\(lit) of \(count) dots lit" }  // copy-budget: spoken
}

private struct FuseRepresentable: NSViewRepresentable {
    let lit: Int
    let count: Int

    func makeNSView(context: Context) -> FuseLayerView { FuseLayerView(count: count, lit: lit) }

    func updateNSView(_ view: FuseLayerView, context: Context) { view.set(lit: lit, animated: true) }
}

/// Layer-backed Fuse. Each dot is an outline layer (always present) under a fill layer whose
/// opacity is 1 when lit and 0 when spent.
final class FuseLayerView: NSView {
    private let count: Int
    private var lit: Int
    private var fills: [CAShapeLayer] = []
    private var outlines: [CAShapeLayer] = []

    static func width(count: Int) -> CGFloat { CGFloat(max(count - 1, 0)) * Metrics.fusePitch + Metrics.fuseDot }

    init(count: Int, lit: Int) {
        self.count = count
        self.lit = lit
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width(count: count), height: Metrics.fuseDot))
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = false
        let d = Metrics.fuseDot
        let fillPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
        let outlinePath = CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: d - 1, height: d - 1), transform: nil)
        for i in 0..<count {
            let frame = CGRect(x: CGFloat(i) * Metrics.fusePitch, y: 0, width: d, height: d)
            let outline = CAShapeLayer()
            outline.frame = frame
            outline.path = outlinePath
            outline.fillColor = nil
            outline.lineWidth = 1
            let fill = CAShapeLayer()
            fill.frame = frame
            fill.path = fillPath
            fill.opacity = i < lit ? 1 : 0
            layer?.addSublayer(outline)
            layer?.addSublayer(fill)
            outlines.append(outline)
            fills.append(fill)
        }
        resolveColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for outline in outlines { outline.strokeColor = Palette.Instrument.spent.cgColor }
            for fill in fills { fill.fillColor = Palette.Instrument.signal.cgColor }
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width(count: count), height: Metrics.fuseDot) }

    /// Dots that go from lit to spent fade over `Timeline.fuseTick`; dots that relight snap on.
    func set(lit new: Int, animated: Bool) {
        let new = min(max(new, 0), count)
        guard new != lit else { return }
        let old = lit
        lit = new
        let may = animated && AnimationGate.mayAnimate(in: window)
        for i in 0..<count {
            let wasLit = i < old, isLit = i < new
            guard wasLit != isLit else { continue }
            if isLit {
                fills[i].removeAllAnimations()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                fills[i].opacity = 1
                CATransaction.commit()
            } else {
                Timeline.fuseTick.run(on: fills[i], key: "fuse.tick", animated: may)
            }
        }
    }
}
