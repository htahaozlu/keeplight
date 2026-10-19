import Foundation
import Testing
@testable import DisplayCore

@Suite("Legacy Dotpitch data")
struct LegacyDataTests {
    private func base() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keeplight-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func thePendingRevertAndDisconnectedDisplaysMoveOnce() throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Dotpitch")
        try write("{\"pending\":1}", old.appendingPathComponent("pending.json"))
        try write("[]", old.appendingPathComponent("disconnected.json"))
        #expect(LegacyData.migrate(base: base, legacyAppRunning: false) == .moved)
        let new = base.appendingPathComponent("Keeplight")
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("pending.json").path))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("disconnected.json").path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(LegacyData.migrate(base: base, legacyAppRunning: false) == .nothing)
    }

    @Test func anEmptyNewFolderIsReplaced() throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        try write("x", base.appendingPathComponent("Dotpitch/journal.jsonl"))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Keeplight"), withIntermediateDirectories: true)
        #expect(LegacyData.migrate(base: base, legacyAppRunning: false) == .moved)
    }

    @Test func aRunningOldAppDefersAndALaterLaunchMergesTheSafetyFiles() throws {
        let base = try base()
        defer { try? FileManager.default.removeItem(at: base) }
        try write("old", base.appendingPathComponent("Dotpitch/pending.json"))
        try write("old", base.appendingPathComponent("Dotpitch/disconnected.json"))
        try write("old", base.appendingPathComponent("Dotpitch/journal.jsonl"))
        try write("", base.appendingPathComponent("Dotpitch/journal.lock"))
        #expect(LegacyData.migrate(base: base, legacyAppRunning: true) == .legacyAppRunning)
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("Dotpitch/pending.json").path))
        // Meanwhile Keeplight wrote its own journal (the case that used to block the move for good).
        try write("new", base.appendingPathComponent("Keeplight/journal.jsonl"))
        #expect(LegacyData.migrate(base: base, legacyAppRunning: false)
            == .merged(files: ["disconnected.json", "pending.json"]))
        let new = base.appendingPathComponent("Keeplight")
        #expect(try String(contentsOf: new.appendingPathComponent("pending.json"), encoding: .utf8) == "old")
        // Files both have stay as they are; the old journal is not overwritten into the new one.
        #expect(try String(contentsOf: new.appendingPathComponent("journal.jsonl"), encoding: .utf8) == "new")
        #expect(LegacyData.migrate(base: base, legacyAppRunning: false) == .nothing)
    }
}
