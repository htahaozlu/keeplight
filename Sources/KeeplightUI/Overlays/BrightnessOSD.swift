import AppKit
import DisplayCore
import QuartzCore
import SwiftUI

/// Level shown by the brightness-key OSD; one window is reused while keys are pressed.
@MainActor @Observable
final class BrightnessOSDState {
    var value: Double = 0
    /// The display's name, shown only when more than one external display can be controlled.
    var name: String?

    init(value: Double = 0, name: String? = nil) {
        self.value = value
        self.name = name
    }
}

/// The brightness-key OSD for DDC displays [A§3.4]: a sun, a capsule track filled in proportion
/// to the level, and the display name when it is ambiguous. No numeral; the panel's slider shows
/// it. Apple displays keep macOS's own OSD.
struct BrightnessOSDView: View {
    static let width: CGFloat = 240
    static let trackSize = CGSize(width: 140, height: 4)
    static let radius: CGFloat = 22

    let state: BrightnessOSDState

    static func height(named: Bool) -> CGFloat { named ? 64 : 44 }

    var body: some View {
        VStack(spacing: 6) {
            if let name = state.name {
                Text(name)
                    .font(.captionText)
                    .foregroundStyle(Color.Instrument.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 14) {
                Image(systemName: state.value <= 0 ? "sun.min" : "sun.max")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.Instrument.ink)
                    .frame(width: 20)
                OSDTrack(value: state.value)
                    .frame(width: Self.trackSize.width, height: Self.trackSize.height)
            }
        }
        .padding(.horizontal, 20)
        .frame(width: Self.width, height: Self.height(named: state.name != nil))
        .instrumentPlate(radius: Self.radius, opacity: 0.90, style: .circular)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OverlayCopy.osdLabel(percent: BrightnessPolicy.percent(state.value)))
    }
}

/// The track: a 4 pt capsule with a white fill whose width follows the level. A change slides
/// the fill over 80 ms (ease-out) when the window may animate.
private struct OSDTrack: NSViewRepresentable {
    let value: Double

    func makeNSView(context: Context) -> OSDTrackView { OSDTrackView(value: value) }

    func updateNSView(_ view: OSDTrackView, context: Context) { view.set(value: value) }
}

final class OSDTrackView: NSView {
    private let fill = CALayer()
    private var value: Double

    init(value: Double) {
        self.value = min(max(value, 0), 1)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = Palette.hex(0x636366).cgColor
        fill.backgroundColor = NSColor.white.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        place(width: width(for: value))
    }

    private func width(for value: Double) -> CGFloat { bounds.width * CGFloat(value) }

    private func place(width: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.isHidden = width < 0.5
        fill.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        fill.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
    }

    func set(value new: Double) {
        let new = min(max(new, 0), 1)
        guard new != value else { return }
        let from = fill.presentation()?.bounds.width ?? width(for: value)
        value = new
        place(width: width(for: new))
        guard (window as? InstrumentPanel)?.mayAnimate ?? AnimationGate.mayAnimate(in: window) else { return }
        let slide = CABasicAnimation(keyPath: "bounds.size.width")
        slide.fromValue = from
        slide.toValue = width(for: new)
        slide.duration = 0.08
        slide.timingFunction = Easing.out.caFunction
        fill.add(slide, forKey: "osd.fill")
    }
}
