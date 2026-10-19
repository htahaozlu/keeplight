import CoreGraphics
import Foundation

/// A risky change that is applied provisionally and must be kept or reverted [O§7.1].
public enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case mode, main, mirror, unmirror, disconnect
    /// A whole-arrangement restore (undoing a rescue).
    case restore

    /// Option used when the change is kept: disconnects last until logout, the rest persist.
    public var keepOption: CGConfigureOption { self == .disconnect ? .forSession : .permanently }

    /// The call that performs the change (for the journal and Raw mode).
    public var mechanism: String {
        switch self {
        case .mode: "CGSConfigureDisplayMode"
        case .main: "CGConfigureDisplayOrigin"
        case .mirror, .unmirror: "CGConfigureDisplayMirrorOfDisplay"
        case .disconnect: "CGSConfigureDisplayEnabled"
        case .restore: "CGCompleteDisplayConfiguration"
        }
    }

    public var journalKind: JournalEntry.Kind {
        switch self {
        case .mode: .mode
        case .main: .main
        case .mirror: .mirror
        case .unmirror: .unmirror
        case .disconnect: .disconnect
        case .restore: .restore
        }
    }
}

/// Why a pending change was reverted (journal `reason`).
public enum RevertReason: String, Codable, CaseIterable, Sendable {
    case timeout, esc, user, sleep
    case displayRemoved = "display-removed"
    case rescue
    case appRelaunch = "app-relaunch"
}

/// Reads and restores the whole display configuration. `DisplayManager` in production
/// (`LiveDisplaySystem`), a fake in tests.
public protocol DisplayApplier: Sendable {
    func snapshot() -> DisplaySnapshot
    func restore(_ snapshot: DisplaySnapshot, option: CGConfigureOption) -> [RestoreStep]
}

/// A provisional change waiting for Keep. The UI owns the countdown; `deadline` is informative.
public struct PendingTransaction: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: TransactionKind
    public let display: DisplayRef
    /// Ring detail line supplied by the caller, e.g. "Desk right · 2560 × 1440 → 3008 × 1692".
    public let summary: String
    /// State before the change, e.g. `2560x1440@60 hidpi`.
    public let before: String
    /// State after the change.
    public let after: String
    public let startedAt: Date
    public let deadline: Date
    /// `id` of the journal entry this change undoes; carried into the `kept` entry only.
    public let undoes: String?
    /// The other display an undo needs (`JournalEntry.counterpart`).
    public var counterpart: String?

    public var displayFingerprint: String { display.fp }
    public var displayName: String { display.name }
}

/// Write-ahead record in `pending.json`.
struct PendingRecord: Codable, Sendable {
    var transaction: PendingTransaction
    var state: String
    var before: DisplaySnapshot
    var after: DisplaySnapshot?
    var ms: Int?
}

/// Result of `TransactionEngine.keep()`.
public struct KeepResult: Sendable {
    public let transaction: PendingTransaction
    public let entry: JournalEntry
    /// Set when re-committing with the keep option failed; the change then still disappears
    /// when the app quits.
    public let recommitError: String?
}

/// Result of `TransactionEngine.revert(reason:)`.
public struct RevertResult: Sendable {
    public let transaction: PendingTransaction
    public let steps: [RestoreStep]
    /// nil when another process (e.g. `keeplight rescue`) had already reverted it.
    public let entry: JournalEntry?
}

/// Runs risky display changes as transactions [O§7.1]:
/// snapshot → `pending.json` (write-ahead, fsync) → apply with `.forAppOnly` → Keep or revert.
///
/// - `keep()` re-applies the change with `.permanently` (`.forSession` for disconnect), journals
///   `kept` and deletes `pending.json`.
/// - `revert(reason:)` restores the snapshot with `.permanently`, journals `reverted` and deletes
///   `pending.json`.
/// - `recoverAtLaunch()` reverts a `pending.json` left by a crash (`app-relaunch`).
///
/// One pending change at a time. Not for the CLI: its process exits right away, and
/// `.forAppOnly` would drop the change; the CLI uses `DirectChange`.
public final class TransactionEngine: @unchecked Sendable {
    public typealias Apply = @Sendable (CGConfigureOption) throws -> Void

    public static let defaultTimeout: TimeInterval = 15

    public let applier: any DisplayApplier
    public let directory: URL
    public let journal: Journal
    public let registry: DisconnectedRegistry
    public let mirrors: MirrorRegistry
    public let source: JournalEntry.Source
    private let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var active: (record: PendingRecord, apply: Apply)?

    public var pendingFileURL: URL { directory.appendingPathComponent("pending.json") }

    public init(applier: any DisplayApplier, directory: URL = Keeplight.supportDirectory, journal: Journal? = nil,
                registry: DisconnectedRegistry? = nil, mirrors: MirrorRegistry? = nil,
                source: JournalEntry.Source = .panel, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.applier = applier
        self.directory = directory
        self.journal = journal ?? Journal(directory: directory, clock: clock)
        self.registry = registry ?? DisconnectedRegistry(directory: directory)
        self.mirrors = mirrors ?? MirrorRegistry(directory: directory)
        self.source = source
        self.clock = clock
    }

    /// The pending change: this process's, else one recorded in `pending.json`.
    public var pending: PendingTransaction? {
        lock.withLock { active?.record.transaction ?? loadRecord()?.transaction }
    }

    /// True when this process's pending change was resolved by another process (CLI, Rescue):
    /// `pending.json` is gone or names a different change.
    public var pendingRevertedElsewhere: Bool {
        lock.withLock {
            guard let active else { return false }
            return loadRecord()?.transaction.id != active.record.transaction.id
        }
    }

    /// Drops this process's record of a change resolved elsewhere, so a new one can begin.
    /// Returns false when there was nothing to drop.
    @discardableResult
    public func forgetRevertedElsewhere() -> Bool {
        lock.withLock {
            guard let active, loadRecord()?.transaction.id != active.record.transaction.id else { return false }
            self.active = nil
            return true
        }
    }

    /// Applies `apply(.forAppOnly)` as a pending change on `display`.
    /// Throws `DisplayError.refused` while another change is pending, and rethrows (after
    /// journaling `failed` and removing `pending.json`) when `apply` fails.
    @discardableResult
    public func begin(kind: TransactionKind, display: DisplayRef, summary: String,
                      timeout: TimeInterval = TransactionEngine.defaultTimeout, undoes: String? = nil,
                      apply: @escaping Apply) throws -> PendingTransaction {
        try lock.withLock {
            guard active == nil, !FileManager.default.fileExists(atPath: pendingFileURL.path) else {
                throw DisplayError.refused("Finish the pending change first")
            }
            let before = applier.snapshot()
            let now = clock()
            let describedBefore = Self.describe(kind, display.fp, in: before, side: .before)
            let counterpart = Self.counterpart(kind.journalKind, display.fp, in: before)
            var record = PendingRecord(
                transaction: PendingTransaction(id: Journal.makeID(), kind: kind, display: display, summary: summary,
                                                before: describedBefore, after: describedBefore, startedAt: now,
                                                deadline: now.addingTimeInterval(timeout), undoes: undoes,
                                                counterpart: counterpart),
                state: "pending", before: before, after: nil, ms: nil)
            try write(record)

            let started = ContinuousClock.now
            do {
                try apply(.forAppOnly)
            } catch {
                FileStore.remove(pendingFileURL)
                try? journal.append(entry(record.transaction, result: .failed, ms: Self.ms(since: started),
                                          detail: String(describing: error)))
                throw error
            }
            let after = applier.snapshot()
            let t = record.transaction
            record.transaction = PendingTransaction(
                id: t.id, kind: kind, display: display, summary: summary, before: t.before,
                after: Self.describe(kind, display.fp, in: after, side: .after), startedAt: t.startedAt,
                deadline: t.deadline, undoes: undoes, counterpart: counterpart)
            record.after = after
            record.ms = Self.ms(since: started)
            try? write(record)
            active = (record, apply)
            return record.transaction
        }
    }

    /// Overload taking the display directly.
    @discardableResult
    public func begin(kind: TransactionKind, display: DisplayInfo, summary: String,
                      timeout: TimeInterval = TransactionEngine.defaultTimeout, undoes: String? = nil,
                      apply: @escaping Apply) throws -> PendingTransaction {
        try begin(kind: kind, display: display.ref, summary: summary, timeout: timeout, undoes: undoes, apply: apply)
    }

    /// Makes the pending change stick: re-applies it with `kind.keepOption`, updates the
    /// disconnected/mirror registries, journals `kept` and deletes `pending.json`.
    @discardableResult
    public func keep() throws -> KeepResult {
        try lock.withLock {
            guard let active else { throw DisplayError.refused("no pending change in this process") }
            guard loadRecord()?.transaction.id == active.record.transaction.id else {
                self.active = nil
                throw DisplayError.refused("the pending change was already reverted")
            }
            let t = active.record.transaction
            var recommitError: String?
            do {
                try active.apply(t.kind.keepOption)
            } catch {
                recommitError = String(describing: error)
            }
            let now = clock()
            if t.kind == .restore {
                try? Bookkeeping.recordRestore(before: active.record.before, after: active.record.after,
                                               registry: registry, mirrors: mirrors, now: now)
            } else {
                try? Bookkeeping.record(t.kind.journalKind, display: t.display,
                                        displayID: active.record.before.entry(for: t.display.fp)?.displayID,
                                        after: active.record.after, registry: registry, mirrors: mirrors, now: now)
            }
            // A failed re-commit leaves the change app-only: it disappears when Keeplight quits.
            var kept = entry(t, result: recommitError == nil ? .kept : .failed, ms: active.record.ms,
                             detail: recommitError.map { "re-commit failed, change lasts until Keeplight quits: \($0)" })
            kept.undoes = t.undoes
            try? journal.append(kept)
            FileStore.remove(pendingFileURL)
            self.active = nil
            return KeepResult(transaction: t, entry: kept, recommitError: recommitError)
        }
    }

    /// Restores the snapshot taken before the pending change (this process's or the one in
    /// `pending.json`), journals `reverted` with `reason` and deletes `pending.json`.
    @discardableResult
    public func revert(reason: RevertReason, source: JournalEntry.Source? = nil) throws -> RevertResult {
        try lock.withLock {
            let onDisk = loadRecord()
            if let active, onDisk?.transaction.id != active.record.transaction.id {
                // Someone else resolved it (CLI rescue); nothing left to undo here.
                self.active = nil
                return RevertResult(transaction: active.record.transaction, steps: [], entry: nil)
            }
            guard let record = active?.record ?? onDisk else { throw DisplayError.refused("no pending change") }
            let started = ContinuousClock.now
            let steps = applier.restore(record.before, option: .permanently)
            let failures = steps.filter { !$0.succeeded }.map { "\($0.action): \($0.error ?? "")" }
            var reverted = entry(record.transaction, result: .reverted, ms: Self.ms(since: started),
                                 detail: failures.isEmpty ? nil : failures.joined(separator: "; "))
            reverted.reason = reason.rawValue
            reverted.source = source ?? self.source
            try? journal.append(reverted)
            FileStore.remove(pendingFileURL)
            active = nil
            return RevertResult(transaction: record.transaction, steps: steps, entry: reverted)
        }
    }

    /// Call once at launch, before any UI (also in safe start): undoes a change left pending by
    /// a previous run. Only the changed display is restored, and only when the display set is
    /// the same and the change is still in effect (`.forAppOnly` usually lets macOS drop it when
    /// the process dies). Otherwise the revert is journaled without touching anything. An
    /// unreadable `pending.json` is removed.
    @discardableResult
    public func recoverAtLaunch() -> RevertResult? {
        lock.withLock {
            guard active == nil, FileManager.default.fileExists(atPath: pendingFileURL.path) else { return nil }
            guard let record = loadRecord() else {
                FileStore.remove(pendingFileURL)
                return nil
            }
            let t = record.transaction
            let current = applier.snapshot()
            var steps: [RestoreStep] = []
            var note: String?
            let started = ContinuousClock.now
            if let target = Self.recoveryTarget(record, current: current) {
                steps = applier.restore(target, option: .permanently)
            } else if Self.sameSet(record.before, current, ignoring: t.kind == .restore ? nil : t.display.fp) {
                note = "already undone by macOS; nothing to restore"
            } else {
                note = "the display set changed since; nothing was restored"
            }
            let failures = steps.filter { !$0.succeeded }.map { "\($0.action): \($0.error ?? "")" }
            var reverted = entry(t, result: .reverted, ms: Self.ms(since: started),
                                 detail: failures.isEmpty ? note : failures.joined(separator: "; "))
            reverted.reason = RevertReason.appRelaunch.rawValue
            reverted.source = .launch
            try? journal.append(reverted)
            FileStore.remove(pendingFileURL)
            return RevertResult(transaction: t, steps: steps, entry: reverted)
        }
    }

    /// The configuration to restore after a crash, limited to what the pending change touched;
    /// nil when the display set changed or the change is no longer in effect.
    static func recoveryTarget(_ record: PendingRecord, current: DisplaySnapshot) -> DisplaySnapshot? {
        let t = record.transaction
        let before = record.before
        guard sameSet(before, current, ignoring: t.kind == .restore ? nil : t.display.fp) else { return nil }
        if let after = record.after {
            // Still in effect only if the touched state now matches what the change produced.
            let stillApplied = t.kind == .restore
                ? DisplaySnapshot.restorePlan(from: current, to: after).isEmpty
                : describe(t.kind, t.display.fp, in: current, side: .after) == t.after
            guard stillApplied, t.after != t.before || t.kind == .restore else { return nil }
        } else if describe(t.kind, t.display.fp, in: current, side: .after) == t.before {
            return nil
        }
        switch t.kind {
        case .restore:
            return before
        case .main:
            var target = current
            for i in target.displays.indices {
                guard let b = before.entry(for: target.displays[i].fingerprint) else { continue }
                target.displays[i].origin = b.origin
                target.displays[i].isMain = b.isMain
            }
            return target
        case .mode, .mirror, .unmirror, .disconnect:
            guard let b = before.entry(for: t.display.fp) else { return nil }
            var target = current
            if let i = target.displays.firstIndex(where: { $0.fingerprint == b.fingerprint }) {
                var e = target.displays[i]
                switch t.kind {
                case .mode: (e.modeNumber, e.modeLabel) = (b.modeNumber, b.modeLabel)
                case .mirror, .unmirror: (e.mirrorSourceFingerprint, e.origin) = (b.mirrorSourceFingerprint, b.origin)
                default: e = b
                }
                target.displays[i] = e
            } else {
                target.displays.append(b)
            }
            return target
        }
    }

    /// Same displays in both snapshots, apart from `ignoring` (the display a disconnect hid).
    static func sameSet(_ a: DisplaySnapshot, _ b: DisplaySnapshot, ignoring fp: String?) -> Bool {
        let set = { (s: DisplaySnapshot) in Set(s.displays.map(\.fingerprint)).subtracting(fp.map { [$0] } ?? []) }
        return set(a) == set(b)
    }

    // MARK: Helpers

    private func loadRecord() -> PendingRecord? {
        guard let data = try? Data(contentsOf: pendingFileURL) else { return nil }
        return try? FileStore.decoder.decode(PendingRecord.self, from: data)
    }

    private func write(_ record: PendingRecord) throws {
        try FileStore.atomicWrite(try FileStore.encoder.encode(record), to: pendingFileURL)
    }

    private func entry(_ t: PendingTransaction, result: JournalEntry.Outcome, ms: Int?,
                       detail: String? = nil) -> JournalEntry {
        JournalEntry(t: clock(), source: source, display: t.display, kind: t.kind.journalKind, before: t.before,
                     after: t.after, mechanism: t.kind.mechanism, result: result, ms: ms, detail: detail,
                     counterpart: t.counterpart)
    }

    /// Fingerprint of the other display an undo of `kind` on `fp` needs, read before the change.
    static func counterpart(_ kind: JournalEntry.Kind, _ fp: String, in snapshot: DisplaySnapshot) -> String? {
        switch kind {
        case .main: snapshot.main.map(\.fingerprint).flatMap { $0 == fp ? nil : $0 }
        case .unmirror: snapshot.entry(for: fp)?.mirrorSourceFingerprint
        default: nil
        }
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    enum Side { case before, after }

    /// Human description of the state `kind` changes, for the ring, receipts and journal.
    static func describe(_ kind: JournalEntry.Kind, _ fp: String, in snapshot: DisplaySnapshot, side: Side) -> String {
        let entry = snapshot.entry(for: fp)
        switch kind {
        case .mode:
            return entry?.modeLabel ?? entry?.modeNumber.map { "mode #\($0)" } ?? "unknown mode"
        case .main:
            return snapshot.main?.name ?? "no main display"
        case .mirror, .unmirror:
            guard let entry, entry.isEnabled, let source = entry.mirrorSourceFingerprint else { return "separate" }
            return "mirrors \(snapshot.entry(for: source)?.name ?? source)"
        case .disconnect, .reconnect:
            return entry?.isEnabled == true ? "connected" : "disconnected"
        case .restore:
            let enabled = snapshot.displays.filter(\.isEnabled).count
            return "\(enabled) display\(enabled == 1 ? "" : "s") on"
        default:
            return side == .before ? "before" : "after"
        }
    }

    static func describe(_ kind: TransactionKind, _ fp: String, in snapshot: DisplaySnapshot, side: Side) -> String {
        describe(kind.journalKind, fp, in: snapshot, side: side)
    }
}

/// Non-transactional changes (CLI): apply directly, update registries, journal `applied`
/// (or `failed`). Never touches `pending.json`.
public struct DirectChange: Sendable {
    public let applier: any DisplayApplier
    public let journal: Journal
    public let registry: DisconnectedRegistry
    public let mirrors: MirrorRegistry
    public let source: JournalEntry.Source
    private let clock: @Sendable () -> Date

    public init(applier: any DisplayApplier, journal: Journal = .standard, registry: DisconnectedRegistry = .standard,
                mirrors: MirrorRegistry = .standard, source: JournalEntry.Source = .cli,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.applier = applier
        self.journal = journal
        self.registry = registry
        self.mirrors = mirrors
        self.source = source
        self.clock = clock
    }

    /// Outcome; `journalError` is set when the change succeeded but could not be journaled.
    public struct Outcome: Sendable {
        public let entry: JournalEntry
        public let journalError: String?
    }

    /// Runs `body` (which applies the change with its permanent/session option), then journals.
    /// `display` names the changed display (the mirror target for mirror/unmirror). When
    /// `displayID` is given and the display is not in the snapshots (reconnect), it is used for
    /// the registry. Rethrows `body`'s error after journaling `failed`.
    @discardableResult
    public func apply(_ kind: JournalEntry.Kind, display: DisplayRef, displayID: CGDirectDisplayID? = nil,
                      mechanism: String? = nil, body: () throws -> Void) throws -> Outcome {
        let before = applier.snapshot()
        let started = ContinuousClock.now
        var entry = JournalEntry(t: clock(), source: source, display: display, kind: kind,
                                 before: TransactionEngine.describe(kind, display.fp, in: before, side: .before),
                                 mechanism: mechanism ?? Self.mechanism(kind), result: .applied,
                                 counterpart: TransactionEngine.counterpart(kind, display.fp, in: before))
        do {
            try body()
        } catch {
            entry.result = .failed
            entry.ms = TransactionEngine.ms(since: started)
            entry.detail = String(describing: error)
            try? journal.append(entry)
            throw error
        }
        entry.ms = TransactionEngine.ms(since: started)
        let after = applier.snapshot()
        entry.after = TransactionEngine.describe(kind, display.fp, in: after, side: .after)
        if kind == .reconnect { entry.after = "connected" }
        try? Bookkeeping.record(kind, display: display,
                                displayID: displayID ?? before.entry(for: display.fp)?.displayID,
                                after: after, registry: registry, mirrors: mirrors, now: entry.t)
        do {
            try journal.append(entry)
            return Outcome(entry: entry, journalError: nil)
        } catch {
            return Outcome(entry: entry, journalError: String(describing: error))
        }
    }

    /// Journals a change whose before/after the caller describes (brightness, DDC writes).
    @discardableResult
    public func record(_ kind: JournalEntry.Kind, display: DisplayRef, before: String?, after: String?,
                       mechanism: String?, body: () throws -> Void) throws -> Outcome {
        let started = ContinuousClock.now
        var entry = JournalEntry(t: clock(), source: source, display: display, kind: kind, before: before,
                                 after: after, mechanism: mechanism, result: .applied)
        var failure: Error?
        do {
            try body()
        } catch {
            failure = error
            entry.result = .failed
            entry.detail = String(describing: error)
        }
        entry.ms = TransactionEngine.ms(since: started)
        var journalError: String?
        do { try journal.append(entry) } catch { journalError = String(describing: error) }
        if let failure { throw failure }
        return Outcome(entry: entry, journalError: journalError)
    }

    static func mechanism(_ kind: JournalEntry.Kind) -> String? {
        switch kind {
        case .mode: TransactionKind.mode.mechanism
        case .main: TransactionKind.main.mechanism
        case .mirror, .unmirror: TransactionKind.mirror.mechanism
        case .disconnect, .reconnect: TransactionKind.disconnect.mechanism
        case .brightness, .ddc, .restore: nil
        }
    }
}
