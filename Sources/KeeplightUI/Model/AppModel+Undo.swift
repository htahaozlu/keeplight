import AppKit
import DisplayCore
import SwiftUI

/// ⌘Z, the receipt's Undo and the status item's Undo: transactional kinds go through a new Keep
/// card, brightness is applied directly.
extension AppModel {
    enum UndoPlan {
        case brightness(id: CGDirectDisplayID, to: Double)
        case transaction(kind: TransactionKind, display: DisplayRef, summary: String, apply: TransactionEngine.Apply)
        case reconnect(DisconnectedDisplay)
        case rescue
    }

    // MARK: Candidates

    /// How many of the newest journal entries the Undo footer looks at.
    static let undoWindow = 64

    /// The latest undoable journal entry of this session that has a plan.
    func latestUndoable() -> JournalEntry? {
        // The newest entries are enough: an undo is always written after the entry it undoes.
        let entries = journal.tail(Self.undoWindow)
        let undone = Journal.undoneIDs(in: entries).union(appUndone)
        var checked = 0
        for entry in entries.reversed() {
            guard entry.session == Journal.currentSession, entry.isUndoable, entry.undoes == nil,
                  !undone.contains(entry.id) else { continue }
            if undoPlan(for: entry) != nil { return entry }
            checked += 1
            if checked >= 12 { break }
        }
        return nil
    }

    func undoPlan(for entry: JournalEntry) -> UndoPlan? {
        if entry.source == .rescue {
            return rescueGroup?.ids.contains(entry.id) == true ? .rescue : nil
        }
        guard let display = entry.display else { return nil }
        let system = self.system
        let item = items.first { $0.fingerprint == display.fp }
        switch entry.kind {
        case .brightness:
            guard let item, let saved = Format.percentValue(entry.before),
                  case .available(let control, _, _) = brightness[item.id] else { return nil }
            // An entry written on the monitor's own 0…1 (its mechanism has no "+ gamma").
            let legacy = control is DimmingBrightness && entry.mechanism == BrightnessBackend.ddc.mechanism
            return .brightness(id: item.id, to: legacy ? DimmingCurve.fromHardware(saved) : saved)
        case .mode:
            guard let item, let before = entry.before, let mode = resolveMode(before, in: item),
                  mode.modeNumber != item.current?.modeNumber else { return nil }
            let (id, number) = (item.id, mode.modeNumber)
            return .transaction(kind: .mode, display: ref(item.info),
                                summary: "\(name(item.info)) · \(item.current?.sizeText ?? "?") → \(mode.sizeText)",
                                apply: { option in try system.setMode(number, for: id, option: option) })
        case .main:
            // The previous main display, by the fingerprint recorded when the change began; the
            // journal only names it, and names don't tell twins apart.
            guard item?.info.isMain == true, let fp = undoCounterparts[entry.id] ?? entry.counterpart,
                  let target = items.first(where: { $0.fingerprint == fp }), !target.info.isMain,
                  !target.info.isMirrorTarget
            else { return nil }
            let id = target.id
            return .transaction(kind: .main, display: ref(target.info), summary: "The menu bar and Dock move there.",
                                apply: { option in try system.setMain(id, option: option) })
        case .mirror:
            guard let item, item.info.isMirrorTarget, entry.before == "separate" else { return nil }
            let id = item.id
            return .transaction(kind: .unmirror, display: ref(item.info), summary: "",
                                apply: { option in try system.unmirror(id, option: option) })
        case .unmirror:
            // The former mirror source, by fingerprint (see `.main`).
            guard let item, !item.info.isMirrorTarget, let fp = undoCounterparts[entry.id] ?? entry.counterpart,
                  let source = items.first(where: { $0.fingerprint == fp }), source.id != item.id,
                  !source.info.isMirrorTarget
            else { return nil }
            let (target, sourceID) = (item.id, source.id)
            return .transaction(kind: .mirror, display: ref(item.info),
                                summary: "\(name(item.info)) shows \(name(source.info)).",
                                apply: { option in try system.mirror(target, of: sourceID, option: option) })
        case .disconnect:
            guard let gone = disconnected.first(where: { $0.fingerprint == display.fp }) else { return nil }
            return .reconnect(gone)
        case .reconnect, .ddc, .restore:
            return nil
        }
    }

    /// The usable mode a journal label (`2560x1440@60 hidpi`) names on `item`.
    private func resolveMode(_ label: String, in item: DisplayItem) -> DisplayMode? {
        guard let spec = try? ModeSpec(label) else { return nil }
        let candidates = item.modes.filter { mode in
            mode.isUsable && mode.width == spec.width && mode.height == spec.height
                && (spec.refreshRate.map { abs(mode.refreshRate - $0) < 0.5 } ?? true)
                && (spec.hiDPI.map { $0 == mode.isHiDPI } ?? true)
        }
        return candidates.max { a, b in
            if a.refreshRate != b.refreshRate { return a.refreshRate < b.refreshRate }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.modeNumber > b.modeNumber
        }
    }

    // MARK: Run

    /// Undoes `entry`, or the footer candidate.
    func undo(_ entry: JournalEntry? = nil) {
        guard let entry = entry ?? undoCandidate?.entry else { return }
        guard !flags.readOnly else { return flashNotice("Debug mode: nothing is written.") }
        guard let plan = undoPlan(for: entry) else { return refreshUndo() }
        finishGestures()
        switch plan {
        case .brightness(let id, let requested):
            guard let item = item(id), case .available(let control, let old, let ms) = brightness[id] else { return }
            // Same range as the slider (`brightnessFloor`).
            let value = BrightnessPolicy.clamp(requested, floor: brightnessFloor(for: id))
            brightness[id] = .available(control: control, value: value, readMs: ms)
            lastBrightnessWrite[id] = Date()
            prefs.lastWritten[item.fingerprint] = LastWritten(value: value, date: Date())
            writeBrightness(value, via: control)
            let undone = JournalEntry(source: .panel, display: ref(item.info), kind: .brightness,
                                      before: "\(BrightnessPolicy.percent(old ?? value))%",
                                      after: "\(BrightnessPolicy.percent(value))%",
                                      mechanism: control.mechanism, result: .applied, undoes: entry.id)
            record(undone)
            journalChanged()
        case .reconnect(let gone):
            reconnect(gone)
            appUndone.insert(entry.id)
            refreshUndo()
        case .transaction(let kind, let display, let summary, let apply):
            runTransaction(kind: kind, display: display, summary: summary, undoes: entry.id, apply: apply)
        case .rescue:
            guard let group = rescueGroup else { return }
            // Planned once, before the transaction: on Keep the live state already equals the
            // target, so a plan computed then would be empty and nothing would be re-committed
            // permanently. The engine's Keep bookkeeping updates the registries.
            // The live setup, with this model's disconnected registry.
            let system = self.system
            let plan = DisplaySnapshot.restorePlan(from: system.snapshot(), to: group.before)
            guard !plan.isEmpty else { return flashNotice("Nothing to undo: the setup already matches.") }
            runTransaction(kind: .restore, display: DisplayRef(name: "All displays", fp: "all"),
                           summary: "Back to the setup before Rescue.", undoes: entry.id) { option in
                let steps = system.execute(plan, option: option)
                if steps.allSatisfy({ !$0.succeeded }) {
                    throw DisplayError.refused(steps.first?.error ?? "nothing could be restored")
                }
            }
        }
    }

    /// Undo from a receipt.
    func undo(receipt: Receipt) {
        switch receipt.undo {
        case .entry(let id)?:
            if let entry = journal.entries().first(where: { $0.id == id }) { undo(entry) }
        case .rescue?:
            if let entry = journal.entries().last(where: { rescueGroup?.ids.contains($0.id) == true }) { undo(entry) }
        case nil:
            break
        }
        self.receipt = nil
    }
}
