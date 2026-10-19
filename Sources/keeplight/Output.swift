import CoreGraphics
import DisplayCore
import Foundation

enum Output {
    static func error(_ message: String) {
        fflush(nil)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// Columns separated by two spaces; `right` holds the indices of right-aligned columns.
    static func table(_ header: [String], _ rows: [[String]], right: Set<Int> = []) {
        let all = [header] + rows
        let widths = header.indices.map { i in all.map { $0[i].count }.max() ?? 0 }
        for row in all {
            let cells = row.enumerated().map { i, cell in
                let pad = String(repeating: " ", count: widths[i] - cell.count)
                return right.contains(i) ? pad + cell : cell + pad
            }
            print(trimTrailing(cells.joined(separator: "  ")))
        }
    }

    static func fields(_ pairs: [(String, String)]) {
        let width = pairs.map(\.0.count).max() ?? 0
        for (key, value) in pairs {
            print(key.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value)
        }
    }

    /// `hexdump -C` layout: offset, 16 bytes split 8+8, printable ASCII.
    static func hexDump(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.enumerated()
                .map { (i, b) in (i == 8 ? " " : "") + String(format: "%02x", b) }
                .joined(separator: " ")
            let ascii = String(decoding: row.map { (0x20..<0x7F).contains($0) ? $0 : 0x2E }, as: UTF8.self)
            return String(format: "%08x", offset) + "  " + hex.padding(toLength: 48, withPad: " ", startingAt: 0)
                + "  |" + ascii + "|"
        }
    }

    private static func trimTrailing(_ s: String) -> String {
        String(s.reversed().drop { $0 == " " }.reversed())
    }
}

enum Format {
    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    static func hex(_ value: some BinaryInteger, digits: Int) -> String {
        let s = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    static func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }

    /// Three-letter PNP manufacturer code packed into a CoreGraphics vendor number.
    static func pnp(_ vendor: UInt32) -> String? {
        let codes = [(vendor >> 10) & 31, (vendor >> 5) & 31, vendor & 31]
        guard vendor >> 15 == 0, codes.allSatisfy({ (1...26).contains($0) }) else { return nil }
        return String(decoding: codes.map { UInt8($0 + 64) }, as: UTF8.self)
    }

    static func bounds(_ rect: CGRect) -> String {
        "\(Int(rect.width))x\(Int(rect.height)) at (\(Int(rect.minX)), \(Int(rect.minY)))"
    }

    static func manufactured(_ edid: EDID) -> String {
        switch edid.manufactureWeek {
        case 0: "\(edid.manufactureYear)"
        case 0xFF: "model year \(edid.manufactureYear)"
        default: "week \(edid.manufactureWeek), \(edid.manufactureYear)"
        }
    }

    static func timing(_ t: EDID.DetailedTiming) -> String {
        "\(t.horizontalActive)x\(t.verticalActive)@\(number((t.refreshRate * 100).rounded() / 100))"
    }

    /// `90s`, `30m`, `1h`, `2d` (or plain seconds) → seconds.
    static func duration(_ text: String) -> TimeInterval? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400, "w": 604_800]
        if let last = t.last, let unit = units[last], let n = Double(t.dropLast()), n >= 0, n.isFinite {
            return n * unit
        }
        return Double(t).flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
    }

    /// `2026-10-15 14:02:11` in the local time zone.
    static func localTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// `before → after` for a journal entry.
    static func change(_ e: JournalEntry) -> String {
        switch (e.before, e.after) {
        case let (b?, a?): "\(b) → \(a)"
        case let (nil, a?): a
        case let (b?, nil): b
        case (nil, nil): "-"
        }
    }
}

extension DisplayInfo {
    /// `Name (id N)` for messages.
    var tag: String { "\(name) (id \(id))" }
}
