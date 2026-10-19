import DisplayCore
import Foundation

/// Product copy that is shared across surfaces.
enum Copy {
    /// Receipt after a revert the user didn't ask for; nil for Esc / Revert.
    static func revertReceipt(_ pending: PendingInfo, reason: RevertReason) -> String? {
        let what: String
        switch pending.kind {
        case .mode: what = "Went back to \(Format.modeLabel(pending.before))"
        case .main: what = "\(pending.before) is main again"
        case .mirror: what = "\(pending.displayName) is separate again"
        case .unmirror: what = "\(pending.displayName) mirrors again"
        case .disconnect: what = "\(pending.displayName) is back"
        case .restore: what = "Went back to the previous setup"
        }
        switch reason {
        case .timeout: return "\(what) · no answer"
        case .sleep: return "\(what) · Mac slept"
        case .displayRemoved: return "\(what) · display left"
        case .appRelaunch: return "\(what) · Keeplight quit"
        case .esc, .user, .rescue: return nil
        }
    }

    /// Receipt after the wake restore.
    static func wakeReceipt(name: String, percent: Int) -> String { "Set \(name) back to \(percent)" }

    /// The one line in the "No brightness control" popover, chosen from the diagnosis facts.
    static func noControlLine(_ report: DiagnosticReport?, display: DisplayInfo) -> String? {
        guard let facts = report?.facts else { return nil }
        if display.isBuiltin || facts.appleBrightness || facts.connection == .builtin {
            return "Apple screens use macOS's own control."
        }
        if facts.isIntel { return "Intel Macs: no DDC/CI in Keeplight yet." }
        if facts.ddcReply == .maxZero { return "This input or picture mode locks brightness." }
        if facts.connection == .virtual || facts.ddcChannel == false {
            return "This dock or cable blocks DDC."
        }
        return "Turn on DDC/CI in the monitor's menu."
    }

    /// Settings › Displays › Brightness: what moves the brightness (`DDC/CI`, `macOS`), or the one
    /// reason there is no control. `Checking…` until the probe, or for a display without control
    /// the diagnosis, has answered.
    static func brightnessLine(_ state: BrightnessState?, report: DiagnosticReport?, display: DisplayInfo) -> String {
        switch state {
        case .available(let control, _, _)?:
            switch control.backend {
            case .ddc: return "Over the cable"
            case .apple: return "By macOS"
            }
        case .unavailable?:
            return noControlLine(report, display: display) ?? checking
        case .probing?, nil:
            return checking
        }
    }

    static let checking = "Checking…"

    /// Undo labels (⌘Z, the status item's Undo).
    static func change(_ entry: JournalEntry) -> String {
        let before = entry.before
        let after = entry.after
        switch entry.kind {
        case .brightness: return "Brightness \(before ?? "?") → \(after ?? "?")"
        case .mode: return "Resolution \(Format.modeLabel(before)) → \(Format.modeLabel(after))"
        case .main: return "Main display \(before ?? "?") → \(after ?? "?")"
        case .mirror: return "Mirroring: \(after ?? "on")"
        case .unmirror: return "Stop mirroring"
        case .disconnect: return "Disconnect"
        case .reconnect: return entry.detail?.hasPrefix("macOS") == true ? "Reconnected by macOS" : "Reconnect"
        case .ddc: return "DDC \(entry.mechanism ?? "") \(before ?? "?") → \(after ?? "?")"
        case .restore: return "Restore setup"
        }
    }

    /// "Restored 2 displays" / "Reconnected LG HDR 4K, stopped mirroring on DELL"
    static func rescueReceipt(_ outcomes: [RescueOutcome], displayCount: Int) -> String {
        var parts: [String] = []
        var failed = 0
        for outcome in outcomes {
            if outcome.error != nil { failed += 1; continue }
            switch outcome.step {
            case .revertPending: parts.append("Reverted the pending change")
            case .reconnect(let d, _): parts.append("Reconnected \(d.name)")
            case .stopMirroring(let d, _): parts.append("Stopped mirroring on \(d.name)")
            case .applyKnownGood(let snapshot, _):
                let n = max(displayCount, snapshot.displays.filter(\.isEnabled).count)
                parts.append("Restored \(Format.plural(n, "display"))")
            case .makeMain(let d, _): parts.append("\(d.name) is main again")
            case .setMode: parts.append("Default sizes restored")
            }
        }
        var seen = Set<String>()
        parts = parts.filter { seen.insert($0).inserted }
        if parts.isEmpty { return failed > 0 ? "Rescue couldn't finish \(Format.plural(failed, "step"))." : "Nothing needed rescuing." }
        var text = parts.joined(separator: ", ")
        if failed > 0 { text += " (\(Format.plural(failed, "step")) failed)" }
        return text
    }

    static let finishPendingFirst = "Finish the pending change first"
    static let disconnectedCaption = "Back after you log out."
    /// The panel's error row when the permanent re-commit failed.
    static let lastsUntilQuit = "Change lasts until Keeplight quits."

    /// Receipt when restoring failed and Rescue ran instead.
    static func revertFailedReceipt(rescue: String) -> String { "Couldn't revert. Rescue ran: \(rescue)" }
}
