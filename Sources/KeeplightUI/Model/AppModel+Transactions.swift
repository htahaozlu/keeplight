import AppKit
import DisplayCore
import os
import SwiftUI

/// Mode / main / mirror / unmirror / disconnect: every one is a transaction. Each waits for
/// Keep on the Keep card.
extension AppModel {
    // MARK: Actions

    func setMode(_ item: DisplayItem, to mode: DisplayMode) {
        guard mode.modeNumber != item.current?.modeNumber, !isSettling else { return }
        let from = item.current
        let name = name(item.info)
        let detail = OverlayCopy.modeSummary(name: name, from: from.map { ($0.sizeText, $0.refreshRate) },
                                             to: (mode.sizeText, mode.refreshRate))
        let (system, id, number) = (system, item.id, mode.modeNumber)
        runTransaction(kind: .mode, display: ref(item.info), summary: detail) { option in
            try system.setMode(number, for: id, option: option)
        }
    }

    func makeMain(_ item: DisplayItem) {
        let (system, id) = (system, item.id)
        let previous = items.first { $0.info.isMain && !$0.info.isMirrorTarget }?.fingerprint
        let started = runTransaction(kind: .main, display: ref(item.info),
                                     summary: "The menu bar and Dock move there.") { option in
            try system.setMain(id, option: option)
        }
        if started, let previous, let t = pending?.id { undoCounterparts[t] = previous }
    }

    /// `target` shows what `source` shows.
    func mirror(_ target: DisplayItem, of source: DisplayItem) {
        let (system, targetID, sourceID) = (system, target.id, source.id)
        runTransaction(kind: .mirror, display: ref(target.info),
                       summary: "\(name(target.info)) shows \(name(source.info)).") { option in
            try system.mirror(targetID, of: sourceID, option: option)
        }
    }

    func stopMirroring(_ target: DisplayItem) {
        let (system, id) = (system, target.id)
        let source = target.info.mirrorSource.flatMap { source in items.first { $0.id == source }?.fingerprint }
        let started = runTransaction(kind: .unmirror, display: ref(target.info), summary: "") { option in
            try system.unmirror(id, option: option)
        }
        if started, let source, let t = pending?.id { undoCounterparts[t] = source }
    }

    func disconnect(_ item: DisplayItem) {
        guard canDisconnect(item) else { return flashNotice("It's your last active screen.") }
        let (system, id) = (system, item.id)
        runTransaction(kind: .disconnect, display: ref(item.info),
                       summary: "It comes back when you log out, or with Reconnect.") { option in
            try system.setEnabled(false, for: id, option: option)
        }
    }

    /// Reconnecting is always safe, so it needs no ring; it is journaled and undoable like any change.
    func reconnect(_ display: DisconnectedDisplay) {
        guard !flags.readOnly else { return flashNotice("Debug mode: nothing is written.") }
        markOwnChange(5)
        let direct = DirectChange(applier: system, journal: journal, registry: registry, mirrors: engine.mirrors,
                                  source: .panel)
        do {
            try direct.apply(.reconnect, display: display.ref, displayID: display.displayID) {
                try system.setEnabled(true, for: display.displayID, option: .forSession)
            }
        } catch {
            report(error)
        }
        journalChanged()
        scheduleRefresh()
    }

    // MARK: Engine

    /// Starts a pending change. Returns false (with a caption or error) when it could not start.
    @discardableResult
    func runTransaction(kind: TransactionKind, display: DisplayRef, summary: String, undoes: String? = nil,
                        apply: @escaping TransactionEngine.Apply) -> Bool {
        guard !flags.readOnly else {
            flashNotice("Debug mode: nothing is written.")
            return false
        }
        guard pending == nil else {
            flashNotice(Copy.finishPendingFirst)
            return false
        }
        finishGestures()
        markOwnChange(4)
        let timeout = TimeInterval(prefs.revertSeconds)
        do {
            let t = try engine.begin(kind: kind, display: display, summary: summary, timeout: timeout,
                                     undoes: undoes, apply: apply)
            let info = PendingInfo(id: t.id, kind: t.kind, displayName: t.displayName,
                                   title: OverlayCopy.keepTitle(t.kind, name: t.displayName, summary: summary),
                                   detail: t.summary.isEmpty ? nil : t.summary, displayFingerprint: t.displayFingerprint,
                                   before: t.before, startedAt: t.startedAt, deadline: t.deadline)
            pending = info
            ringInfo = info
            ringPhase = .live
            whyExpanded = []
            registerEscape()
            shell?.showRing()
            armKeep()
            announce(OverlayCopy.keepAnnouncement(info.title, seconds: Int(timeout)))
            armDeadline(info)
            scheduleRefresh()
            return true
        } catch {
            report(error)
            scheduleRefresh()
            return false
        }
    }

    private func registerEscape() {
        services.hotKeys.register(.escape, onPress: { [weak self] in self?.revertPending(.esc) }, onRelease: nil)
    }

    func unregisterEscape() { services.hotKeys.unregister(.escape) }

    private func armDeadline(_ info: PendingInfo) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            // VoiceOver hears the question again at 5 s and 2 s left.
            for seconds in [5, 2] {
                try? await Task.sleep(for: .seconds(max(0, info.deadline.timeIntervalSinceNow - Double(seconds))))
                guard !Task.isCancelled, let self, self.pending?.id == info.id else { return }
                self.announce(OverlayCopy.keepAnnouncement(info.title, seconds: seconds))
            }
            try? await Task.sleep(for: .seconds(max(0, info.deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.pending?.id == info.id else { return }
            self.revertPending(.timeout)
        }
    }

    /// Starts the Keep arming delay; call right after the Keep card is shown.
    func armKeep() {
        ringShownUptime = ProcessInfo.processInfo.systemUptime
        keepArmedAt = ringShownUptime + Self.keepArmDelay
    }

    /// Keep (⏎, the button): re-applies permanently; the card shows `Kept`.
    func keepPending() {
        // Keep is armed only after the card has been up briefly, so the keystroke or click that
        // picked the change (or a bounce) can't confirm it while the screen may still be blank.
        guard pending != nil, ProcessInfo.processInfo.systemUptime >= keepArmedAt else { return }
        guard !flags.readOnly else { return resolveDebugPending(.sealed(Date())) }
        deadlineTask?.cancel()
        unregisterEscape()
        markOwnChange(4)
        do {
            let result = try engine.keep()
            if let message = result.recommitError {
                errorMessage = Copy.lastsUntilQuit
                keepLog.error("re-commit failed: \(message, privacy: .public)")
            }
            if result.transaction.kind == .restore, let group = rescueGroup {
                appUndone.formUnion(group.ids)
                rescueGroup = nil
            }
            if let fp = undoCounterparts.removeValue(forKey: result.transaction.id) {
                undoCounterparts[result.entry.id] = fp
            }
            pending = nil
            ringPhase = .sealed(Date())
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
            announce("Kept.")
            finishRing()
            if result.recommitError == nil { scheduleKnownGoodSave(after: 60) }
        } catch {
            // Reverted behind our back (rescue from the CLI, display removed).
            report(error)
            if let id = pending?.id { undoCounterparts[id] = nil }
            pending = nil
            ringPhase = .reverted(Date())
            finishRing()
        }
        journalChanged()
        scheduleRefresh()
    }

    /// Revert (⎋, the button, timeout, sleep, display removed, rescue); the card shows `Reverted`.
    func revertPending(_ reason: RevertReason) {
        guard let info = pending else { return }
        guard !flags.readOnly else { return resolveDebugPending(.reverted(Date())) }
        deadlineTask?.cancel()
        unregisterEscape()
        markOwnChange(4)
        let failed: Bool
        do {
            failed = try engine.revert(reason: reason).hadFailures
        } catch {
            // Nothing was reverted here (the CLI or another instance resolved it): no `Reverted`.
            report(error)
            undoCounterparts[info.id] = nil
            pending = nil
            shell?.dismissRing(animated: false)
            ringInfo = nil
            journalChanged()
            refresh()
            return
        }
        undoCounterparts[info.id] = nil
        pending = nil
        ringPhase = failed ? .revertFailed(Date()) : .reverted(Date())
        if !failed, let text = Copy.revertReceipt(info, reason: reason) { showReceipt(text) }
        announce(failed ? "\(OverlayCopy.revertFailed)." : "Reverted.")
        if reason == .sleep {
            shell?.dismissRing(animated: false)
            ringInfo = nil
        } else {
            finishRing()
        }
        journalChanged()
        if failed, reason != .sleep {
            // The display may not be where it was: Rescue takes over, journaled like any rescue.
            runRescue(afterFailedRevert: true)
        } else {
            if failed { showReceipt("\(OverlayCopy.revertFailed).") }
            refresh()
        }
    }

    /// Debug mode previews a card without an engine transaction; resolving it touches nothing.
    private func resolveDebugPending(_ phase: RingPhase) {
        deadlineTask?.cancel()
        pending = nil
        ringPhase = phase
        finishRing()
    }

    /// The pending change was resolved without us (the CLI or Rescue reverted it): drop the
    /// card, the Esc hotkey and the deadline. Runs on refresh, on reconfiguration and every
    /// second while a change is pending.
    func syncPendingAfterExternalRevert() {
        guard let info = pending, !flags.readOnly, engine.pendingRevertedElsewhere || engine.pending == nil
        else { return }
        engine.forgetRevertedElsewhere()
        deadlineTask?.cancel()
        unregisterEscape()
        undoCounterparts[info.id] = nil
        pending = nil
        ringPhase = .reverted(Date())
        announce("Reverted.")
        finishRing()
        journalChanged()
    }

    /// Once a second while a change is pending, on the second boundary of its countdown: checks
    /// for an external revert and ticks the Keep card's Fuse. This is the Fuse's only clock.
    func watchPending() {
        pendingCheckTask?.cancel()
        pendingCheckTask = nil
        guard let info = pending else { return }
        pendingCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(info.startedAt)
                let next = floor(max(elapsed, 0)) + 1
                try? await Task.sleep(for: .seconds(next - elapsed + 0.01))
                guard !Task.isCancelled, let self, self.pending?.id == info.id else { return }
                self.syncPendingAfterExternalRevert()
                self.shell?.syncRing()
            }
        }
    }

    /// The resolved card (`Kept` / `Reverted`) holds and fades inside the shell.
    private func finishRing() {
        shell?.syncRing()
        shell?.dismissRing(animated: true)
    }

    /// A display went away while a change was pending: the changed display itself, or (for a
    /// pending disconnect) the last other physical screen.
    func checkPendingTarget(_ online: [DisplayInfo]) {
        guard let info = pending, info.kind != .restore else { return }
        if info.kind == .disconnect {
            let othersRemain = online.contains {
                $0.fingerprint != info.displayFingerprint && $0.isOnline && $0.isActive && !$0.isMirrorTarget
                    && isPhysical($0.id)
            }
            if !othersRemain { revertPending(.displayRemoved) }
        } else if !online.contains(where: { $0.fingerprint == info.displayFingerprint && $0.isOnline }) {
            revertPending(.displayRemoved)
        }
    }

    // MARK: Quit and sleep

    func systemWillSleep() {
        asleep = true
        knownGoodTask?.cancel()
        autoRescueTask?.cancel()
        finishGestures()
        cancelProbes()
        pendingRestore = []
        revertPending(.sleep)
    }
}

private let keepLog = Logger(subsystem: "io.github.htahaozlu.Keeplight", category: "keep")
