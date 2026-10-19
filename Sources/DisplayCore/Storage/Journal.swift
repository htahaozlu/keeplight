import Darwin
import Foundation
import Security

/// One line of `journal.jsonl` [O§7.2]. `id`, `session`, `undoes` and `detail` extend the
/// documented schema; readers ignore keys they do not know.
public struct JournalEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable {
        case panel, cli, wake, launch, rescue, sentinel
    }

    public enum Kind: String, Codable, Sendable {
        case mode, main, mirror, unmirror, disconnect, reconnect, brightness
        /// Any other DDC/CI VCP write (CLI `ddc set`).
        case ddc
        /// A whole-arrangement restore (rescue applying a known-good snapshot).
        case restore
    }

    public enum Outcome: String, Codable, Sendable {
        case kept, reverted, failed, applied, restored
    }

    public var id: String
    public var t: Date
    public var source: Source
    public var display: DisplayRef?
    public var kind: Kind
    public var before: String?
    public var after: String?
    public var mechanism: String?
    public var result: Outcome
    /// `timeout|esc|user|sleep|display-removed|rescue|app-relaunch|app-not-responding|…`
    public var reason: String?
    public var ms: Int?
    /// Login session the entry was written in (`Journal.currentSession`).
    public var session: String?
    /// `id` of the entry this one undoes.
    public var undoes: String?
    /// Human-readable extra, e.g. an error message.
    public var detail: String?
    /// Fingerprint of the other display involved, needed to undo: the previous main display
    /// (`main`) or the former mirror source (`unmirror`).
    public var counterpart: String?

    public init(id: String = Journal.makeID(), t: Date = Date(), source: Source, display: DisplayRef?, kind: Kind,
                before: String? = nil, after: String? = nil, mechanism: String? = nil, result: Outcome,
                reason: String? = nil, ms: Int? = nil, session: String? = Journal.currentSession,
                undoes: String? = nil, detail: String? = nil, counterpart: String? = nil) {
        self.id = id
        self.t = t
        self.source = source
        self.display = display
        self.kind = kind
        self.before = before
        self.after = after
        self.mechanism = mechanism
        self.result = result
        self.reason = reason
        self.ms = ms
        self.session = session
        self.undoes = undoes
        self.detail = detail
        self.counterpart = counterpart
    }

    /// Kept, applied and restored entries can be undone.
    public var isUndoable: Bool { [.kept, .applied, .restored].contains(result) }
}

/// Append-only JSONL change log shared by the app and the CLI (`flock`-serialized).
/// Keeps at most `maxEntries` entries and nothing older than `maxAge`; pruning runs on append.
public final class Journal: Sendable {
    public static let standard = Journal(directory: Keeplight.supportDirectory)

    public let directory: URL
    public let maxEntries: Int
    public let maxAge: TimeInterval
    private let clock: @Sendable () -> Date

    public var fileURL: URL { directory.appendingPathComponent("journal.jsonl") }
    private var lockURL: URL { directory.appendingPathComponent(".journal.lock") }

    public init(directory: URL, maxEntries: Int = 1_000, maxAge: TimeInterval = 90 * 86_400,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.maxEntries = maxEntries
        self.maxAge = maxAge
        self.clock = clock
    }

    public func append(_ entry: JournalEntry) throws {
        var line = try FileStore.encoder.encode(entry)
        line.append(0x0A)
        try FileStore.withLock(lockURL) {
            try FileStore.append(line, to: fileURL)
            try pruneLocked(onlyIfNeeded: true)
        }
    }

    /// Entries in file (chronological) order, optionally only those at or after `since`.
    /// Lines that do not decode are skipped.
    public func entries(since: Date? = nil) -> [JournalEntry] {
        let all = Self.decode((try? Data(contentsOf: fileURL)) ?? Data())
        guard let since else { return all }
        return all.filter { $0.t >= since }
    }

    /// The last `count` entries, oldest first, read from the end of the file without decoding the
    /// rest. An entry that undoes another is always written after it, so a tail holds both.
    public func tail(_ count: Int) -> [JournalEntry] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }
        var window: UInt64 = 16 * 1024
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            // A window that starts mid-file begins with a partial line.
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            if start == 0 || lines.count > count {
                return Self.decode(lines.suffix(count).reduce(into: Data()) { $0.append(contentsOf: $1); $0.append(0x0A) })
            }
            window *= 4
        }
    }

    /// The latest entry of `session` that can be undone and has not been undone yet.
    /// Undo entries themselves are skipped, so repeated undo walks back through history.
    /// `excluding` marks further entries as already undone (e.g. the other steps of a rescue
    /// that was undone as a whole).
    public func undoable(inSession session: String = Journal.currentSession,
                         excluding: Set<String> = []) -> JournalEntry? {
        Self.undoable(in: entries(), session: session, excluding: excluding)
    }

    /// IDs of entries that a later entry undid.
    public static func undoneIDs(in entries: [JournalEntry]) -> Set<String> {
        Set(entries.compactMap(\.undoes))
    }

    static func undoable(in entries: [JournalEntry], session: String,
                         excluding: Set<String> = []) -> JournalEntry? {
        let undone = undoneIDs(in: entries).union(excluding)
        return entries.last { entry in
            entry.session == session && entry.isUndoable && entry.undoes == nil && !undone.contains(entry.id)
        }
    }

    /// Drops entries beyond `maxEntries` (oldest first) and older than `maxAge`.
    public func prune() throws {
        try FileStore.withLock(lockURL) { try pruneLocked(onlyIfNeeded: false) }
    }

    /// Deletes every entry.
    public func clear() throws {
        try FileStore.withLock(lockURL) { FileStore.remove(fileURL) }
    }

    private func pruneLocked(onlyIfNeeded: Bool) throws {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        let cutoff = clock().addingTimeInterval(-maxAge)
        if onlyIfNeeded {
            let lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            let firstLine = data.prefix { $0 != 0x0A }
            let oldest = Self.decode(Data(firstLine)).first?.t
            guard lines > maxEntries || (oldest.map { $0 < cutoff } ?? false) else { return }
        }
        let kept = Self.decode(data).filter { $0.t >= cutoff }.suffix(maxEntries)
        var out = Data()
        for entry in kept {
            out.append(try FileStore.encoder.encode(entry))
            out.append(0x0A)
        }
        try FileStore.atomicWrite(out, to: fileURL)
    }

    private static func decode(_ data: Data) -> [JournalEntry] {
        data.split(separator: 0x0A).compactMap { try? FileStore.decoder.decode(JournalEntry.self, from: Data($0)) }
    }

    public static func makeID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    /// Identifies the current login session: boot time plus the security (audit) session ID,
    /// so the app and a CLI run from Terminal in the same login agree.
    public static let currentSession: String = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        var session = SecuritySessionId()
        var attributes = SessionAttributeBits()
        let status = SessionGetInfo(SecuritySessionId(bitPattern: -1), &session, &attributes)
        return status == errSecSuccess ? "\(boot.tv_sec)-\(session)" : "\(boot.tv_sec)-pid\(getpid())"
    }()
}

/// Coalesces brightness changes into gestures for the journal: a slider drag, scroll burst
/// or key-repeat run separated by less than `gap` is one entry (first before → last after).
/// Gestures whose rounded percentage did not change are dropped.
public struct BrightnessGestureCoalescer: Sendable {
    public struct Gesture: Hashable, Sendable {
        public var display: DisplayRef
        /// 0...1
        public var before: Double
        /// 0...1
        public var after: Double
        public var mechanism: String?
        public var startedAt: Date
        public var lastAt: Date

        /// A journal entry for this gesture (`before`/`after` as whole percentages).
        public func entry(source: JournalEntry.Source = .panel,
                          result: JournalEntry.Outcome = .applied) -> JournalEntry {
            JournalEntry(t: lastAt, source: source, display: display, kind: .brightness,
                         before: Self.percent(before), after: Self.percent(after), mechanism: mechanism,
                         result: result, ms: Int((lastAt.timeIntervalSince(startedAt) * 1000).rounded()))
        }

        static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

        var isNoOp: Bool { (before * 100).rounded() == (after * 100).rounded() }
    }

    public let gap: TimeInterval
    private var open: [String: Gesture] = [:]

    public init(gap: TimeInterval = 0.8) {
        self.gap = gap
    }

    /// Records one change. Returns the display's previous gesture when this change starts a new one.
    public mutating func record(_ display: DisplayRef, from before: Double, to after: Double,
                                mechanism: String? = nil, at now: Date) -> [Gesture] {
        var finished: [Gesture] = []
        if var current = open[display.fp], now.timeIntervalSince(current.lastAt) < gap {
            current.after = after
            current.lastAt = now
            current.display.name = display.name
            open[display.fp] = current
            return []
        } else if let previous = open[display.fp], !previous.isNoOp {
            finished.append(previous)
        }
        open[display.fp] = Gesture(display: display, before: before, after: after, mechanism: mechanism,
                                   startedAt: now, lastAt: now)
        return finished
    }

    /// Gestures idle for at least `gap` at `now`; call from a timer or when the panel closes.
    public mutating func flush(at now: Date) -> [Gesture] {
        let done = open.values.filter { now.timeIntervalSince($0.lastAt) >= gap }
        for gesture in done { open[gesture.display.fp] = nil }
        return done.filter { !$0.isNoOp }.sorted { $0.lastAt < $1.lastAt }
    }

    /// Every open gesture, regardless of age (quit, sleep).
    public mutating func finishAll() -> [Gesture] {
        let done = open.values.filter { !$0.isNoOp }.sorted { $0.lastAt < $1.lastAt }
        open.removeAll()
        return done
    }

    public var hasOpenGestures: Bool { !open.isEmpty }
}
