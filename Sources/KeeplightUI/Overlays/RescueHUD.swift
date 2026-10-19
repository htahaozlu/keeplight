import SwiftUI

/// What the rescue HUD shows (hold ⌃⌥⌘R).
enum RescueHUDPhase: Equatable {
    /// Holding: `lit` of 5 Fuse dots remain.
    case holding(lit: Int)
    /// Done: the result sentence replaces the title and the Fuse.
    case done(String, ok: Bool = true)
    /// Released early or finished: gone at once.
    case hidden
}

/// Which HUD showing the shell is on: a press while the previous result is still up starts over,
/// and the old result's fade must not close the new HUD.
struct RescueHUDLifecycle {
    private(set) var generation = 0
    private(set) var isVisible = false
    private(set) var showsResult = false

    /// The chord is held. True when the HUD must play its appearance (first time, or over a result).
    mutating func holding() -> Bool {
        let replay = !isVisible || showsResult
        isVisible = true
        showsResult = false
        if replay { generation += 1 }
        return replay
    }

    /// The result is up; the returned ticket closes it when its time is over.
    mutating func showResult() -> Int {
        isVisible = true
        showsResult = true
        generation += 1
        return generation
    }

    mutating func hide() {
        isVisible = false
        showsResult = false
        generation += 1
    }

    func shouldClose(ticket: Int) -> Bool { isVisible && generation == ticket }
}

@MainActor @Observable
final class RescueHUDState {
    var phase = RescueHUDPhase.holding(lit: RescueHUDView.dots)

    init(phase: RescueHUDPhase = .holding(lit: RescueHUDView.dots)) { self.phase = phase }
}

/// The rescue HUD [A§3.8]: `Keep holding to restore` and a 5-dot Fuse that burns down, then the
/// result. Same card as Identify, on every screen.
struct RescueHUDView: View {
    static let dots = 5

    let state: RescueHUDState

    var body: some View {
        VStack(spacing: 12) {
            switch state.phase {
            case .holding(let lit):
                Text(OverlayCopy.rescueHolding)
                    .font(.cardTitle)
                    .foregroundStyle(Color.Instrument.ink)
                Fuse(lit: lit, count: Self.dots)
                    .accessibilityHidden(true)
            case .done(let text, let ok):
                Text(text)
                    .font(.cardTitle)
                    .foregroundStyle(Color.Instrument.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Image(systemName: ok ? "checkmark" : "exclamationmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.Instrument.ink)
                    .frame(height: Metrics.fuseDot)
                    .padding(.vertical, 6)
                    .accessibilityHidden(true)
            case .hidden:
                EmptyView()
            }
        }
        .padding(24)
        .frame(width: Metrics.rescueCardSize.width, height: Metrics.rescueCardSize.height)
        .instrumentPlate()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state.phase {
        case .holding: OverlayCopy.rescueHolding
        case .done(let text, _): text
        case .hidden: ""
        }
    }
}

extension Timeline {
    /// The rescue result: hold 1.6 s, fade out over 160 ms. The short first segment lets an
    /// interrupted card-in settle from the pose on screen.
    static let rescueDone = Timeline(
        keyframes: [Keyframe(time: 0, pose: Pose(opacity: 1)),
                    Keyframe(time: 0.06, pose: Pose(opacity: 1), easing: .out),
                    Keyframe(time: 1.6, pose: Pose(opacity: 1), easing: .linear),
                    Keyframe(time: 1.76, pose: Pose(opacity: 0), easing: .in)],
        explanationTime: 0)
}
