import Foundation
import Testing
@testable import DisplayCore

private let desk = DisplayRef(name: "Desk right", fp: "DEL:A0F3:4C3V2K3")

private func brightness(_ before: String, _ after: String, at t: Date, session: String = "s1",
                        result: JournalEntry.Outcome = .applied, undoes: String? = nil) -> JournalEntry {
    JournalEntry(t: t, source: .panel, display: desk, kind: .brightness, before: before, after: after,
                 result: result, session: session, undoes: undoes)
}

@Test func journalAppendsAndReadsJSONL() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let clock = TestClock()
    let journal = Journal(directory: dir.url, clock: clock.function)
    let first = JournalEntry(t: clock.now, source: .cli, display: desk, kind: .mode, before: "2560x1440@60 hidpi",
                             after: "3008x1692@60 hidpi", mechanism: "CGSConfigureDisplayMode", result: .applied,
                             ms: 184)
    try journal.append(first)
    try journal.append(brightness("40%", "55%", at: clock.now.addingTimeInterval(60)))
    let entries = journal.entries()
    #expect(entries.count == 2)
    #expect(entries[0] == first)
    #expect(journal.entries(since: clock.now.addingTimeInterval(30)).map(\.kind) == [.brightness])

    // One JSON object per line with the documented keys.
    let text = try String(contentsOf: journal.fileURL, encoding: .utf8)
    let lines = text.split(separator: "\n")
    #expect(lines.count == 2)
    let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    #expect(object?["t"] as? String == "2027-01-15T08:00:00Z")
    #expect(object?["source"] as? String == "cli")
    #expect((object?["display"] as? [String: String])?["fp"] == "DEL:A0F3:4C3V2K3")
    #expect(object?["result"] as? String == "applied")
    #expect(object?["ms"] as? Int == 184)

    // Garbage lines are skipped, not fatal.
    try FileStore.append(Data("not json\n".utf8), to: journal.fileURL)
    #expect(journal.entries().count == 2)
}

@Test func journalPrunesByCountAndAge() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let clock = TestClock()
    let journal = Journal(directory: dir.url, maxEntries: 5, maxAge: 3_600, clock: clock.function)
    for i in 0..<8 {
        try journal.append(brightness("\(i)%", "\(i + 1)%", at: clock.now.addingTimeInterval(Double(i))))
    }
    #expect(journal.entries().map(\.before) == ["3%", "4%", "5%", "6%", "7%"])  // newest 5 kept

    clock.advance(3_600 + 4.5)  // entries 0...4 are now older than an hour
    try journal.prune()
    #expect(journal.entries().map(\.before) == ["5%", "6%", "7%"])

    // Appending also prunes when the oldest entry has expired.
    clock.advance(10)
    try journal.append(brightness("a", "b", at: clock.now))
    #expect(journal.entries().map(\.before) == ["a"])
    try journal.clear()
    #expect(journal.entries().isEmpty)
}

@Test func journalUndoableInSession() throws {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    let a = brightness("10%", "20%", at: t)
    let b = brightness("20%", "30%", at: t.addingTimeInterval(1))
    let reverted = JournalEntry(t: t.addingTimeInterval(2), source: .panel, display: desk, kind: .mode,
                                result: .reverted, session: "s1")
    let otherSession = brightness("1%", "2%", at: t.addingTimeInterval(3), session: "s0")
    var entries = [a, b, reverted, otherSession]
    #expect(Journal.undoable(in: entries, session: "s1") == b)
    // Undoing b records an entry pointing at it; the next undo walks back to a.
    entries.append(brightness("30%", "20%", at: t.addingTimeInterval(4), undoes: b.id))
    #expect(Journal.undoable(in: entries, session: "s1") == a)
    #expect(Journal.undoable(in: entries, session: "s2") == nil)

    let dir = TempDir()
    defer { dir.cleanup() }
    let journal = Journal(directory: dir.url)
    try journal.append(JournalEntry(source: .cli, display: desk, kind: .main, result: .applied))
    #expect(journal.undoable()?.kind == .main)  // default: the current login session
    #expect(!Journal.currentSession.isEmpty)
}

@Test func brightnessGesturesCoalesce() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var c = BrightnessGestureCoalescer()
    // One drag: 40 → 45 → 55 within 800 ms gaps.
    #expect(c.record(desk, from: 0.40, to: 0.45, mechanism: "DDC VCP 0x10", at: t0).isEmpty)
    #expect(c.record(desk, from: 0.45, to: 0.50, at: t0.addingTimeInterval(0.5)).isEmpty)
    #expect(c.record(desk, from: 0.50, to: 0.55, at: t0.addingTimeInterval(1.2)).isEmpty)
    #expect(c.flush(at: t0.addingTimeInterval(1.5)).isEmpty)  // still inside the gap
    // A new change after a ≥ 800 ms pause closes the first gesture.
    let closed = c.record(desk, from: 0.55, to: 0.60, at: t0.addingTimeInterval(2.1))
    #expect(closed.count == 1)
    #expect(closed[0].before == 0.40 && closed[0].after == 0.55)
    let entry = closed[0].entry()
    #expect(entry.kind == .brightness && entry.before == "40%" && entry.after == "55%" && entry.ms == 1_200)
    #expect(entry.mechanism == "DDC VCP 0x10")

    // Flush returns gestures idle for the gap; a gesture that went back to its start is dropped.
    let other = DisplayRef(name: "Built-in", fp: "APP:A059:1")
    _ = c.record(other, from: 0.30, to: 0.35, at: t0.addingTimeInterval(2.2))
    _ = c.record(other, from: 0.35, to: 0.30, at: t0.addingTimeInterval(2.3))
    let flushed = c.flush(at: t0.addingTimeInterval(3.2))
    #expect(flushed.map(\.display.fp) == [desk.fp])
    #expect(flushed[0].before == 0.55 && flushed[0].after == 0.60)
    #expect(!c.hasOpenGestures)
    _ = c.record(desk, from: 0.6, to: 0.7, at: t0.addingTimeInterval(10))
    #expect(c.finishAll().count == 1)
}
