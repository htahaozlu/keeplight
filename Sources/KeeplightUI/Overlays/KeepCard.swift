import SwiftUI

/// What the Keep card shows. One instance feeds the card on every screen.
@MainActor @Observable
final class KeepCardState {
    enum Phase: Equatable { case live, kept, reverted, revertFailed }

    var title = ""
    var phase = Phase.live
    /// Lit Fuse dots, from the model's per-second state.
    var lit = Metrics.fuseCount
    /// Seconds each Fuse dot stands for (the change's duration ÷ the dot count).
    var secondsPerDot = 1.0
    /// Card height; nil lets the card size itself (minimum `Metrics.keepCardSize`).
    var height: CGFloat?

    init(title: String = "", phase: Phase = .live, lit: Int = Metrics.fuseCount, secondsPerDot: Double = 1,
         height: CGFloat? = nil) {
        self.title = title
        self.phase = phase
        self.lit = lit
        self.secondsPerDot = secondsPerDot
        self.height = height
    }

    /// What VoiceOver reads for the card: the question while live, the outcome once resolved.
    var accessibilityText: String {
        switch phase {
        case .live: OverlayCopy.keepCardLabel(title: title, lit: lit, secondsPerDot: secondsPerDot)
        case .kept: OverlayCopy.kept
        case .reverted: OverlayCopy.reverted
        case .revertFailed: OverlayCopy.revertFailed
        }
    }
}

/// The Keep card [A§3.2]: the question, the Fuse (time until Keeplight puts it back), `Revert`
/// and `Keep`. Resolved, one word and a symbol replace everything but the plate.
struct KeepCardView: View {
    let state: KeepCardState
    var onKeep: () -> Void = {}
    var onRevert: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            switch state.phase {
            case .live: live
            case .kept: resolved(OverlayCopy.kept, symbol: "checkmark")
            case .reverted: resolved(OverlayCopy.reverted, symbol: "arrow.uturn.backward")
            case .revertFailed: resolved(OverlayCopy.revertFailed, symbol: "exclamationmark")
            }
        }
        .padding(24)
        .frame(width: Metrics.keepCardSize.width, height: state.height)
        .frame(minHeight: state.height == nil ? Metrics.keepCardSize.height : nil)
        .instrumentPlate()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.accessibilityText)
    }

    @ViewBuilder
    private var live: some View {
        Text(state.title)
            .font(.cardTitle)
            .foregroundStyle(Color.Instrument.ink)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        Fuse(lit: state.lit)
            .accessibilityHidden(true)
        HStack(spacing: 12) {
            Button(OverlayCopy.revertButton, action: onRevert)
                .buttonStyle(CardButtonStyle())
                .hitTarget("Revert")
                .help("Esc")
                .accessibilityHint("Escape")
            Button(OverlayCopy.keepButton, action: onKeep)
                .buttonStyle(CardButtonStyle(prominent: true))
                .hitTarget("Keep")
                .help("Return")
                .accessibilityHint("Return")
        }
    }

    @ViewBuilder
    private func resolved(_ word: String, symbol: String) -> some View {
        Text(word)
            .font(.cardTitle)
            .foregroundStyle(Color.Instrument.ink)
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color.Instrument.ink)
            .frame(height: Metrics.fuseDot)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }
}

extension Timeline {
    /// `Kept` / `Reverted`: hold 700 ms, then fade over 160 ms. The short first segment lets an
    /// interrupted card-in settle from the pose on screen. The explanation frame is the hold.
    static let cardResolved = Timeline(
        keyframes: [Keyframe(time: 0, pose: Pose(opacity: 1)),
                    Keyframe(time: 0.06, pose: Pose(opacity: 1), easing: .out),
                    Keyframe(time: 0.7, pose: Pose(opacity: 1), easing: .linear),
                    Keyframe(time: 0.86, pose: Pose(opacity: 0), easing: .in)],
        explanationTime: 0)
}
