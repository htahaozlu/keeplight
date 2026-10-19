import DisplayCore
import Foundation

/// Words on the overlays and the safe-start row [A§4]. Onboarding has its own (`OnboardingCopy`).
enum OverlayCopy {
    // MARK: Keep card

    /// The Keep card question. `summary` is the transaction summary; a mode change carries its
    /// target size after the last `→`.
    static func keepTitle(_ kind: TransactionKind, name: String, summary: String) -> String {
        switch kind {
        case .mode:
            guard let size = targetSize(in: summary) else { return "Keep this size?" }
            // Same size, other refresh rate (or HiDPI): the size alone would not name the change.
            if let rate = rateOfUnchangedSize(in: summary) { return "Keep \(size) · \(rate)?" }
            return "Keep \(size)?"
        case .main: return "Keep \(name) as main?"
        case .mirror: return "Keep mirroring?"
        case .unmirror: return "Keep displays separate?"
        case .disconnect: return "Keep \(name) disconnected?"
        case .restore: return "Keep this setup?"
        }
    }

    /// "DELL U2723QE · 2560 × 1440 → 3008 × 1692 · 120 Hz" → "3008 × 1692".
    static func targetSize(in summary: String) -> String? {
        guard let arrow = summary.range(of: "→ ", options: .backwards) else { return nil }
        let tail = summary[arrow.upperBound...]
        let size = tail.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return size.isEmpty ? nil : size
    }

    /// The Keep card's detail line for a mode change. The rate is added when it changes, and
    /// whenever the size stays (then the rate is what names the change).
    static func modeSummary(name: String, from: (size: String, rate: Double)?, to: (size: String, rate: Double)) -> String {
        var detail = "\(name) · \(from?.size ?? "?") → \(to.size)"
        if let from, from.size == to.size || abs(from.rate - to.rate) > 0.5 { detail += " · \(Format.hz(to.rate)) Hz" }
        return detail
    }

    /// "120 Hz" when the summary's size does not change and it names a rate; else nil.
    static func rateOfUnchangedSize(in summary: String) -> String? {
        guard let arrow = summary.range(of: "→ ", options: .backwards) else { return nil }
        let from = summary[..<arrow.lowerBound].components(separatedBy: " · ").last?
            .trimmingCharacters(in: .whitespaces)
        let parts = summary[arrow.upperBound...].components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let to = parts.first, from == to else { return nil }
        return parts.dropFirst().first { $0.hasSuffix(" Hz") }
    }

    static let kept = "Kept"
    static let reverted = "Reverted"
    static let revertFailed = "Couldn't revert"
    static let keepButton = "Keep"
    static let revertButton = "Revert"

    /// VoiceOver says "times" for ×.
    static func spoken(_ title: String) -> String { title.replacingOccurrences(of: " × ", with: " by ") }

    /// "Keep 3008 by 1692? Goes back in 15 seconds."
    static func keepAnnouncement(_ title: String, seconds: Int) -> String {
        "\(spoken(title)) Goes back in \(Format.plural(seconds, "second"))."  // copy-budget: spoken
    }

    /// VoiceOver for the live Keep card: the question and the time left, which is the lit dots ×
    /// the seconds each dot stands for.
    static func keepCardLabel(title: String, lit: Int, secondsPerDot: Double) -> String {
        let seconds = secondsLeft(lit: lit, secondsPerDot: secondsPerDot)
        return "\(spoken(title)) \(Format.plural(seconds, "second")) until it goes back."  // copy-budget: spoken
    }

    static func secondsLeft(lit: Int, secondsPerDot: Double) -> Int {
        max(0, Int((Double(lit) * secondsPerDot).rounded()))
    }

    // MARK: Brightness OSD

    static func osdLabel(percent: Int) -> String { "Brightness \(percent) percent" }  // copy-budget: spoken

    // MARK: Identify

    static func identifyAnnouncement(_ names: [String]) -> String {
        names.map { "This is \($0)" }.joined(separator: ". ")  // copy-budget: spoken
    }

    // MARK: Rescue HUD

    static let rescueHolding = "Keep holding to restore"
    static let rescueNothing = "Nothing needed rescuing."
    static let rescueFailed = "Rescue could not finish."

    static func rescueRestored(displays: Int) -> String { "Restored \(Format.plural(displays, "display"))" }

    // MARK: Safe start

    static let safeStart = "Safe start: nothing applied."
    static let rescue = "Rescue"
    static let continueLabel = "Continue"
}
