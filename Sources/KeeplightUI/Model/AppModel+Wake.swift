import AppKit
import DisplayCore
import SwiftUI

/// Wake, hotplug and the safety nets around them [O§7.6]: settle before touching hardware,
/// accept what macOS did, save known-good setups, rescue when no screen is left.
extension AppModel {
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Reconfiguration

    /// A display reconfiguration finished (hotplug, wake, our own change).
    func reconfigured() {
        services.dimmer.reapply()
        syncPendingAfterExternalRevert()
        // Known-good needs a stable setup: a reconfiguration that isn't ours cancels the save.
        // Until the launch save has happened, it starts over instead.
        if Date() >= ownChangeUntil {
            knownGoodTask?.cancel()
            if !launchKnownGoodSaved { scheduleKnownGoodSave(after: 30) }
        }
        scheduleRefresh()
        scheduleAutoRescueCheck()
        if isSettling { noteSettleEvent() }
    }

    func systemDidWake() {
        lastWake = Date()
        services.dimmer.reapply(liftingBelow: DimmingCurve.wakeGain)
        if isSettling {
            noteSettleEvent()
        } else {
            beginSettling(wake: true)
        }
        restoreAfterSettle = true
    }

    // MARK: Settling

    func beginSettling(wake: Bool) {
        guard !flags.debug || wake else { return }
        cancelProbes()
        isSettling = true
        restoreAfterSettle = restoreAfterSettle || wake
        settle = SettleWindow(start: uptime)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let window = self.settle else { return }
                if window.isSettled(at: ProcessInfo.processInfo.systemUptime) {
                    self.endSettling()
                    return
                }
            }
        }
    }

    func noteSettleEvent() {
        settle?.note(uptime)
    }

    private func endSettling() {
        isSettling = false
        settle = nil
        settleTask = nil
        let wake = restoreAfterSettle
        restoreAfterSettle = false
        if wake { asleep = false }
        refresh()
        // Auto-rescue acts only if no screen is left now that the hardware has settled.
        scheduleAutoRescueCheck(settled: true)
        if wake, prefs.restoreAfterWake, automaticChangesAllowed {
            pendingRestore = Set(items.map(\.fingerprint))
        }
        // Everything re-probes, with back-off: DDC services come back a little after the display.
        probeBrightness(items.map(\.info))
    }

    // MARK: macOS reconnecting what we disconnected

    /// Displays Keeplight disconnected that macOS brought back (wake, hotplug): accept it.
    func acceptReconnectedByMacOS(_ online: [DisplayInfo]) {
        guard !flags.readOnly else { return }
        let active = Set(online.filter { $0.isActive && $0.isOnline }.map(\.fingerprint))
        for entry in registry.load() where active.contains(entry.fingerprint) {
            try? registry.remove(fingerprint: entry.fingerprint)
            let journalEntry = JournalEntry(source: .wake, display: entry.ref, kind: .reconnect,
                                            before: "disconnected", after: "connected",
                                            mechanism: TransactionKind.disconnect.mechanism, result: .applied,
                                            detail: "macOS reconnected \(entry.name)")
            record(journalEntry)
            journalChanged()
        }
    }

    // MARK: Known good

    /// Saves the current setup as known-good once it has been stable for `seconds` with nothing
    /// pending. Scheduled only 30 s after launch and 60 s after a kept change; a reconfiguration
    /// that isn't ours, or sleep, cancels it.
    func scheduleKnownGoodSave(after seconds: TimeInterval) {
        guard automaticChangesAllowed, !erased else { return }
        knownGoodTask?.cancel()
        knownGoodTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.automaticChangesAllowed, !self.erased, self.pending == nil,
                  !self.isSettling, !self.asleep, !self.items.isEmpty else { return }
            try? self.knownGood.save(self.system.snapshot())
            self.launchKnownGoodSaved = true
        }
    }

    // MARK: Auto-rescue

    /// Auto-rescue may act: not in debug, not while settling, not from sleep until the wake settle
    /// ends (`endSettling` checks again). It stays on in safe start: it only reconnects screens.
    private var autoRescueAllowed: Bool {
        !flags.readOnly && !isSettling && !asleep
    }

    /// When no physical display is enabled, revert a pending disconnect and reconnect everything
    /// we disconnected: within 500 ms after our own change, otherwise only if it still holds once
    /// the hardware has settled (`settled`: called from `endSettling`).
    func scheduleAutoRescueCheck(settled: Bool = false) {
        autoRescueTask?.cancel()
        guard autoRescueAllowed else { return }
        autoRescueTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.autoRescueAllowed, self.rescue.needsAutoRescue() else { return }
            // Nothing of ours to undo (e.g. a desk of only virtual displays): don't settle or freeze.
            guard !self.registry.load().isEmpty || self.pending?.kind == .disconnect else { return }
            if !settled, Date() >= self.ownChangeUntil {
                self.beginSettling(wake: false)
                return
            }
            if self.pending?.kind == .disconnect { self.revertPending(.displayRemoved) }
            guard !self.registry.load().isEmpty,
                  let outcomes = self.rescue.autoRescueIfNeeded(), !outcomes.isEmpty else { return }
            self.knownGoodTask?.cancel()
            self.launchKnownGoodSaved = true  // a rescued setup isn't known-good until a change is kept
            self.markOwnChange(5)
            self.journalChanged()
            self.scheduleRefresh()
            self.showReceipt(Copy.rescueReceipt(outcomes, displayCount: 0))
        }
    }
}
