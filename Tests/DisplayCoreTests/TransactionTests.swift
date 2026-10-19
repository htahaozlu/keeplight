import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore

private let builtinFP = "APP:A059:1"
private let deskFP = "DEL:A0F3:SN"
private let desk = DisplayRef(name: "Desk right", fp: deskFP)

private func twoDisplays() -> FakeSystem {
    FakeSystem([
        entry(builtinFP, id: 1, name: "Built-in", mode: 54, label: "1512x982@120 hidpi", main: true, builtin: true),
        entry(deskFP, id: 3, name: "Desk right", mode: 90, label: "2560x1440@60 hidpi", x: 1512),
    ])
}

private func setMode(_ number: Int32, _ label: String) -> @Sendable (inout DisplaySnapshot) -> Void {
    { $0.set(deskFP) { $0.modeNumber = number; $0.modeLabel = label } }
}

private struct Harness {
    let dir = TempDir()
    let clock = TestClock()
    let system = twoDisplays()
    var journal: Journal { Journal(directory: dir.url, clock: clock.function) }

    func engine() -> TransactionEngine {
        TransactionEngine(applier: system, directory: dir.url, clock: clock.function)
    }
}

@Test func beginWritesAheadAndAppliesForAppOnly() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    let pending = try engine.begin(kind: .mode, display: desk, summary: "Desk right · 2560 × 1440 → 3008 × 1692",
                                   timeout: 15, apply: h.system.apply(setMode(91, "3008x1692@60 hidpi")))
    #expect(h.system.applyOptions == [.forAppOnly])
    #expect(pending.kind == .mode && pending.displayFingerprint == deskFP && pending.displayName == "Desk right")
    #expect(pending.before == "2560x1440@60 hidpi" && pending.after == "3008x1692@60 hidpi")
    #expect(pending.deadline == h.clock.now.addingTimeInterval(15))
    #expect(h.dir.exists("pending.json"))
    #expect(engine.pending == pending)

    // The write-ahead record carries the before snapshot, so a fresh engine (another
    // process) sees the same pending change.
    let record = try FileStore.decoder.decode(PendingRecord.self,
                                              from: Data(contentsOf: engine.pendingFileURL))
    #expect(record.state == "pending")
    #expect(record.before.entry(for: deskFP)?.modeNumber == 90)
    #expect(record.after?.entry(for: deskFP)?.modeNumber == 91)
    #expect(h.engine().pending?.id == pending.id)
    #expect(h.journal.entries().isEmpty)  // nothing is journaled until keep or revert
}

@Test func onlyOnePendingAtATime() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    try engine.begin(kind: .mode, display: desk, summary: "", apply: h.system.apply(setMode(91, "b")))
    #expect(throws: DisplayError.self) {
        try engine.begin(kind: .main, display: desk, summary: "", apply: h.system.apply { _ in })
    }
    // A pending.json from another process blocks too.
    #expect(throws: DisplayError.self) {
        try h.engine().begin(kind: .main, display: desk, summary: "", apply: h.system.apply { _ in })
    }
    #expect(h.system.applyOptions == [.forAppOnly])  // the refused changes never ran
}

@Test func keepRecommitsPermanentlyAndJournals() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    try engine.begin(kind: .mode, display: desk, summary: "", apply: h.system.apply(setMode(91, "3008x1692@60 hidpi")))
    h.clock.advance(5)
    let result = try engine.keep()
    #expect(h.system.applyOptions == [.forAppOnly, .permanently])
    #expect(result.recommitError == nil)
    #expect(!h.dir.exists("pending.json"))
    #expect(engine.pending == nil)
    let entries = h.journal.entries()
    #expect(entries.count == 1)
    #expect(entries[0].result == .kept && entries[0].kind == .mode && entries[0].source == .panel)
    #expect(entries[0].before == "2560x1440@60 hidpi" && entries[0].after == "3008x1692@60 hidpi")
    #expect(entries[0].mechanism == "CGSConfigureDisplayMode")
    #expect(h.system.restored.isEmpty)
    #expect(throws: DisplayError.self) { try engine.keep() }  // nothing pending any more
}

@Test func keepDisconnectIsForSessionAndRegisters() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    try engine.begin(kind: .disconnect, display: desk, summary: "",
                     apply: h.system.apply { $0.set(deskFP) { $0.isEnabled = false } })
    #expect(engine.pending?.after == "disconnected")
    try engine.keep()
    #expect(h.system.applyOptions == [.forAppOnly, .forSession])
    let registered = DisconnectedRegistry(directory: h.dir.url).load()
    #expect(registered.map(\.fingerprint) == [deskFP])
    #expect(registered.first?.displayID == 3)
}

@Test func keepMirrorRecordsCreatedMirror() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    try engine.begin(kind: .mirror, display: desk, summary: "",
                     apply: h.system.apply { $0.set(deskFP) { $0.mirrorSourceFingerprint = builtinFP } })
    #expect(engine.pending?.after == "mirrors Built-in")
    try engine.keep()
    #expect(MirrorRegistry(directory: h.dir.url).load().first?.sourceFingerprint == builtinFP)
}

@Test func revertRestoresSnapshotPermanently() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    let before = h.system.snapshot()
    try engine.begin(kind: .mode, display: desk, summary: "", apply: h.system.apply(setMode(91, "3008x1692@60 hidpi")))
    let result = try engine.revert(reason: .timeout)
    #expect(h.system.restoreOptions == [.permanently])
    #expect(h.system.restored == [before])
    #expect(h.system.state.entry(for: deskFP)?.modeNumber == 90)
    #expect(result.steps.map(\.action) == [.setMode(desk, modeNumber: 90, label: "2560x1440@60 hidpi")])
    #expect(!h.dir.exists("pending.json"))
    let entries = h.journal.entries()
    #expect(entries.map(\.result) == [.reverted])
    #expect(entries[0].reason == "timeout")
    #expect(entries[0].before == "2560x1440@60 hidpi" && entries[0].after == "3008x1692@60 hidpi")
    #expect(throws: DisplayError.self) { try engine.revert(reason: .esc) }

    #expect(RevertReason.allCases.map(\.rawValue)
            == ["timeout", "esc", "user", "sleep", "display-removed", "rescue", "app-relaunch"])
}

@Test func failedApplyLeavesNothingPending() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    h.system.failNextApply = true
    #expect(throws: DisplayError.self) {
        try engine.begin(kind: .main, display: desk, summary: "", apply: h.system.apply { _ in })
    }
    #expect(!h.dir.exists("pending.json"))
    #expect(engine.pending == nil)
    #expect(h.journal.entries().map(\.result) == [.failed])
    // The guard is released: the next change can start.
    try engine.begin(kind: .main, display: desk, summary: "", apply: h.system.apply { _ in })
}

@Test func recoverAtLaunchRevertsLeftoverPending() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let before = h.system.snapshot()
    // A previous run applied a change and died before Keep.
    try h.engine().begin(kind: .mode, display: desk, summary: "", apply: h.system.apply(setMode(91, "x")))

    let relaunched = h.engine()
    let result = try #require(relaunched.recoverAtLaunch())
    #expect(result.transaction.kind == .mode)
    #expect(h.system.restored == [before])
    #expect(h.system.restoreOptions == [.permanently])
    #expect(!h.dir.exists("pending.json"))
    let entry = try #require(h.journal.entries().last)
    #expect(entry.result == .reverted && entry.reason == "app-relaunch" && entry.source == .launch)
    #expect(relaunched.recoverAtLaunch() == nil)  // nothing left

    // A corrupt pending.json is discarded instead of blocking every future change.
    try Data("{".utf8).write(to: relaunched.pendingFileURL)
    #expect(relaunched.recoverAtLaunch() == nil)
    #expect(!h.dir.exists("pending.json"))
}

@Test func revertByAnotherProcessIsNotDoubleApplied() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let app = h.engine()
    try app.begin(kind: .mode, display: desk, summary: "", apply: h.system.apply(setMode(91, "x")))
    // `keeplight rescue` reverts it from pending.json.
    try h.engine().revert(reason: .rescue, source: .rescue)
    #expect(h.system.restored.count == 1)
    // The app's countdown then fires: nothing more is restored or journaled.
    let late = try app.revert(reason: .timeout)
    #expect(late.entry == nil && late.steps.isEmpty)
    #expect(h.system.restored.count == 1)
    #expect(h.journal.entries().map(\.reason) == ["rescue"])
    #expect(throws: DisplayError.self) { try app.keep() }
}

@Test func directChangeIsCLISafe() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let direct = DirectChange(applier: h.system, journal: h.journal, registry: DisconnectedRegistry(directory: h.dir.url),
                              mirrors: MirrorRegistry(directory: h.dir.url), clock: h.clock.function)
    let apply = h.system.apply(setMode(91, "3008x1692@60 hidpi"))
    let outcome = try direct.apply(.mode, display: desk) { try apply(.permanently) }
    #expect(outcome.journalError == nil)
    #expect(h.system.applyOptions == [.permanently])  // never .forAppOnly
    #expect(!h.dir.exists("pending.json"))
    #expect(outcome.entry.source == .cli && outcome.entry.result == .applied)
    #expect(outcome.entry.before == "2560x1440@60 hidpi" && outcome.entry.after == "3008x1692@60 hidpi")

    // A disconnect from the CLI is remembered for the app and rescue.
    try direct.apply(.disconnect, display: desk) { h.system.state.set(deskFP) { $0.isEnabled = false } }
    #expect(DisconnectedRegistry(directory: h.dir.url).load().first?.displayID == 3)
    try direct.apply(.reconnect, display: desk, displayID: 3) { h.system.state.set(deskFP) { $0.isEnabled = true } }
    #expect(DisconnectedRegistry(directory: h.dir.url).load().isEmpty)

    // Failures are journaled and rethrown.
    #expect(throws: DisplayError.self) {
        try direct.apply(.main, display: desk) { throw DisplayError.refused("no") }
    }
    let entries = h.journal.entries()
    #expect(entries.map(\.result) == [.applied, .applied, .applied, .failed])
    #expect(entries.map(\.kind) == [.mode, .disconnect, .reconnect, .main])
    #expect(entries.allSatisfy { $0.source == .cli })

    // While a transaction is pending, a CLI change still applies directly.
    let engine = h.engine()
    try engine.begin(kind: .main, display: desk, summary: "", apply: h.system.apply { _ in })
    try direct.record(.brightness, display: desk, before: "40%", after: "50%", mechanism: "DDC VCP 0x10") {}
    #expect(h.journal.entries().last?.kind == .brightness)
}

@Test func undoLinkIsJournaledOnlyWhenKept() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    // A reverted undo leaves the original undoable.
    try engine.begin(kind: .mode, display: desk, summary: "", undoes: "orig1",
                     apply: h.system.apply(setMode(91, "3008x1692@60 hidpi")))
    #expect(engine.pending?.undoes == "orig1")
    try engine.revert(reason: .esc)
    #expect(h.journal.entries().last?.undoes == nil)
    // A kept undo carries the link, so the original stops being undoable.
    try engine.begin(kind: .mode, display: desk, summary: "", undoes: "orig1",
                     apply: h.system.apply(setMode(91, "3008x1692@60 hidpi")))
    try engine.keep()
    let entries = h.journal.entries()
    #expect(entries.last?.result == .kept && entries.last?.undoes == "orig1")
    #expect(Journal.undoneIDs(in: entries) == ["orig1"])
}

@Test func restoreKindJournalsAsRestore() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    try engine.begin(kind: .restore, display: desk, summary: "",
                     apply: h.system.apply(setMode(91, "3008x1692@60 hidpi")))
    #expect(engine.pending?.before == "2 displays on")
    let kept = try engine.keep()
    #expect(kept.entry.kind == .restore && kept.entry.mechanism == "CGCompleteDisplayConfiguration")
    #expect(h.system.applyOptions == [.forAppOnly, .permanently])
}

@Test func undoableCanExcludeAGroup() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let journal = h.journal
    let a = JournalEntry(t: h.clock.now, source: .rescue, display: desk, kind: .reconnect, result: .applied, session: "s")
    let b = JournalEntry(t: h.clock.now, source: .rescue, display: desk, kind: .mode, result: .applied, session: "s")
    try journal.append(a)
    try journal.append(b)
    #expect(journal.undoable(inSession: "s")?.id == b.id)
    #expect(journal.undoable(inSession: "s", excluding: [b.id])?.id == a.id)
    #expect(journal.undoable(inSession: "s", excluding: [a.id, b.id]) == nil)
}

@Test func detectsRevertByAnotherProcess() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let app = h.engine()
    try app.begin(kind: .mode, display: desk, summary: "", apply: h.system.apply(setMode(91, "3008x1692@60 hidpi")))
    #expect(!app.pendingRevertedElsewhere)

    // The CLI (another engine on the same directory) reverts it.
    try h.engine().revert(reason: .rescue, source: .cli)
    #expect(!h.dir.exists("pending.json"))
    #expect(app.pendingRevertedElsewhere)
    #expect(app.forgetRevertedElsewhere())
    #expect(app.pending == nil)
    #expect(!app.pendingRevertedElsewhere)
    #expect(throws: DisplayError.self) { try app.keep() }
}

@Test func recoverAtLaunchLeavesAnUndoneChangeAlone() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    try h.engine().begin(kind: .mode, display: desk, summary: "", apply: h.system.apply(setMode(91, "3008x1692@60 hidpi")))
    // macOS dropped the app-only change when the process died.
    h.system.state.set(deskFP) { $0.modeNumber = 90; $0.modeLabel = "2560x1440@60 hidpi" }
    let result = try #require(h.engine().recoverAtLaunch())
    #expect(result.steps.isEmpty && h.system.restored.isEmpty)
    #expect(h.journal.entries().last?.detail?.contains("already undone") == true)
    #expect(!h.dir.exists("pending.json"))
}

@Test func recoverAtLaunchSkipsAChangedDisplaySet() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    try h.engine().begin(kind: .mode, display: desk, summary: "", apply: h.system.apply(setMode(91, "x")))
    h.system.state.displays.removeAll { $0.fingerprint == builtinFP }  // lid closed, another desk
    let result = try #require(h.engine().recoverAtLaunch())
    #expect(result.steps.isEmpty && h.system.restored.isEmpty)
    #expect(h.journal.entries().last?.detail?.contains("display set changed") == true)
}

@Test func recoverAtLaunchRestoresOnlyTheChangedDisplay() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    try h.engine().begin(kind: .mode, display: desk, summary: "", apply: h.system.apply(setMode(91, "x")))
    h.system.state.set(builtinFP) { $0.modeNumber = 55 }  // changed in System Settings after the crash
    _ = try #require(h.engine().recoverAtLaunch())
    #expect(h.system.state.entry(for: deskFP)?.modeNumber == 90)
    #expect(h.system.state.entry(for: builtinFP)?.modeNumber == 55)
}

@Test func recoverAtLaunchReconnectsADisconnectStillInEffect() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    try h.engine().begin(kind: .disconnect, display: desk, summary: "",
                         apply: h.system.apply { $0.displays.removeAll { $0.fingerprint == deskFP } })
    _ = try #require(h.engine().recoverAtLaunch())
    #expect(h.system.state.entry(for: deskFP)?.isEnabled == true)
}

@Test func keptRestoreRecordsDisconnectedDisplays() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    try engine.begin(kind: .restore, display: DisplayRef(name: "All displays", fp: "all"), summary: "",
                     apply: h.system.apply { $0.displays.removeAll { $0.fingerprint == deskFP } })
    let kept = try engine.keep()
    #expect(kept.entry.result == .kept)
    #expect(DisconnectedRegistry(directory: h.dir.url).load().map(\.fingerprint) == [deskFP])
}

@Test func keptRestoreRecordsMirrors() throws {
    let h = Harness()
    defer { h.dir.cleanup() }
    let engine = h.engine()
    try engine.begin(kind: .restore, display: DisplayRef(name: "All displays", fp: "all"), summary: "",
                     apply: h.system.apply { $0.set(deskFP) { $0.mirrorSourceFingerprint = builtinFP } })
    try engine.keep()
    #expect(MirrorRegistry(directory: h.dir.url).load().map(\.target.fp) == [deskFP])
}
