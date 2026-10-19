import AppKit
import DisplayCore
import SwiftUI

/// Rescue [O§7.3]: the hold chord, the panel's Rescue button and safe start.
extension AppModel {
    /// How long ⌃⌥⌘R is held before Rescue runs. Someone without a usable screen can't wait long,
    /// so it stays at 1.5 s; the HUD's 5-dot Fuse burns down over the time left after it appears.
    static let rescueHold: Duration = .milliseconds(1500)
    /// The HUD appears after this much holding, so a stray tap shows nothing.
    static let rescueHUDDelay: Duration = .milliseconds(400)

    /// What a rescue did, for the HUD.
    enum RescueResult: Equatable {
        case restored(displays: Int)
        case nothing
        case failed

        var text: String {
            switch self {
            case .restored(let displays): OverlayCopy.rescueRestored(displays: displays)
            case .nothing: OverlayCopy.rescueNothing
            case .failed: OverlayCopy.rescueFailed
            }
        }
    }

    // MARK: Hold ⌃⌥⌘R

    /// Hold ⌃⌥⌘R: after 400 ms the HUD shows `Keep holding to restore` and a 5-dot Fuse that goes
    /// out evenly until 1.5 s, when Rescue runs and the HUD shows the result. Releasing early
    /// removes the HUD at once. Every wait is to an absolute time since the press.
    func beginRescueHold() {
        rescueHoldTask?.cancel()
        let total = RescueHUDView.dots
        let step = (Self.rescueHold - Self.rescueHUDDelay) / total
        rescueHoldTask = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            try? await clock.sleep(until: start + Self.rescueHUDDelay)
            guard !Task.isCancelled, let self else { return }
            self.shell?.rescueHUD(.holding(lit: total))
            for dot in 1...total {
                try? await clock.sleep(until: start + Self.rescueHUDDelay + step * dot)
                guard !Task.isCancelled else { return }
                if dot < total { self.shell?.rescueHUD(.holding(lit: total - dot)) }
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            self.rescueHoldTask = nil
            let result = self.runRescue()
            self.shell?.rescueHUD(.done(result.text, ok: result != .failed))
        }
    }

    func cancelRescueHold() {
        guard rescueHoldTask != nil else { return }
        rescueHoldTask?.cancel()
        rescueHoldTask = nil
        shell?.rescueHUD(.hidden)
    }

    // MARK: Run

    /// Reverts a pending change, reconnects, stops our mirrors and restores the known-good setup.
    /// `afterFailedRevert`: Rescue was started because restoring a pending change failed; the
    /// receipt and the journal say so.
    @discardableResult
    func runRescue(afterFailedRevert: Bool = false) -> RescueResult {
        guard !flags.readOnly else {
            flashNotice("Debug mode: nothing is written.")
            return .nothing
        }
        finishGestures()
        deadlineTask?.cancel()
        // A rescued setup is not known-good until the user keeps a change on top of it.
        knownGoodTask?.cancel()
        launchKnownGoodSaved = true
        let before = system.snapshot()
        let started = Date().addingTimeInterval(-1)
        markOwnChange(6)
        // A screen too dark to read is part of what rescue is for.
        services.dimmer.resetAll()
        // On the main thread: display enumeration touches NSScreen, and the work takes well under a second.
        let outcomes = rescue.run()
        return rescueFinished(outcomes, before: before, since: started, afterFailedRevert: afterFailedRevert)
    }

    private func rescueFinished(_ outcomes: [RescueOutcome], before: DisplaySnapshot, since: Date,
                                afterFailedRevert: Bool) -> RescueResult {
        syncPendingAfterExternalRevert()
        let entries = journal.entries(since: since).filter { $0.source == .rescue }
        let ids = Set(entries.map(\.id))
        let enabled = system.snapshot().displays.filter(\.isEnabled).count
        var text = Copy.rescueReceipt(outcomes, displayCount: enabled)
        if afterFailedRevert {
            text = Copy.revertFailedReceipt(rescue: text)
            if outcomes.isEmpty {
                record(JournalEntry(source: .rescue, display: nil, kind: .restore, result: .failed,
                                    reason: "revert-failed",
                                    detail: "Restoring the previous setup failed; Rescue found nothing more to do."))
            }
        }
        if outcomes.isEmpty || ids.isEmpty {
            showReceipt(text)
        } else {
            rescueGroup = (ids, before)
            showReceipt(text, undo: .rescue)
        }
        journalChanged()
        scheduleRefresh()
        if outcomes.isEmpty { return .nothing }
        return outcomes.contains { $0.error == nil } ? .restored(displays: enabled) : .failed
    }
}
