import Foundation
import Testing
@testable import DisplayCore

private func entry(_ n: Int, at t: Date) -> JournalEntry {
    JournalEntry(t: t, source: .panel, display: DisplayRef(name: "Desk", fp: "DEL:A0F3:1"), kind: .brightness,
                 before: "\(n)%", after: "\(n + 1)%", result: .applied)
}

@Suite struct JournalTailTests {
    @Test func tailReturnsTheLastEntriesOldestFirst() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let clock = TestClock()
        let journal = Journal(directory: dir.url, clock: clock.function)
        for n in 0..<300 { try journal.append(entry(n, at: clock.now)) }
        let tail = journal.tail(5)
        #expect(tail.map(\.before) == ["295%", "296%", "297%", "298%", "299%"])
        #expect(tail == Array(journal.entries().suffix(5)))
    }

    @Test func tailWiderThanTheReadWindowStillFindsEveryEntry() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let clock = TestClock()
        let journal = Journal(directory: dir.url, clock: clock.function)
        // ~200 bytes per line: 400 entries are well past the first 16 KiB window.
        for n in 0..<400 { try journal.append(entry(n, at: clock.now)) }
        #expect(journal.tail(300) == Array(journal.entries().suffix(300)))
    }

    @Test func tailOfAShortOrMissingJournal() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let clock = TestClock()
        let journal = Journal(directory: dir.url, clock: clock.function)
        #expect(journal.tail(10).isEmpty)
        try journal.append(entry(1, at: clock.now))
        try journal.append(entry(2, at: clock.now))
        #expect(journal.tail(10).map(\.before) == ["1%", "2%"])
        #expect(journal.tail(0).isEmpty)
    }
}
