import Foundation

/// MCCS VCP feature codes.
public struct VCP: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let brightness = VCP(rawValue: 0x10)
    public static let contrast = VCP(rawValue: 0x12)
    public static let redGain = VCP(rawValue: 0x16)
    public static let greenGain = VCP(rawValue: 0x18)
    public static let blueGain = VCP(rawValue: 0x1A)
    public static let inputSource = VCP(rawValue: 0x60)
    public static let volume = VCP(rawValue: 0x62)
    public static let mute = VCP(rawValue: 0x8D)
    public static let powerMode = VCP(rawValue: 0xD6)
    public static let factoryReset = VCP(rawValue: 0x04)

    private static let names: [(String, VCP)] = [
        ("brightness", .brightness), ("contrast", .contrast), ("volume", .volume),
        ("mute", .mute), ("input", .inputSource), ("inputsource", .inputSource),
        ("power", .powerMode), ("powermode", .powerMode),
        ("red", .redGain), ("redgain", .redGain),
        ("green", .greenGain), ("greengain", .greenGain),
        ("blue", .blueGain), ("bluegain", .blueGain),
        ("factoryreset", .factoryReset),
    ]

    private static let canonical: [UInt8: String] = [
        0x10: "brightness", 0x12: "contrast", 0x16: "redGain", 0x18: "greenGain",
        0x1A: "blueGain", 0x60: "inputSource", 0x62: "volume", 0x8D: "mute",
        0xD6: "powerMode", 0x04: "factoryReset",
    ]

    /// Name lookup for CLI input (`brightness`, `volume`, `0x10`, `16`).
    public init?(name: String) {
        let t = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let hit = Self.names.first(where: { $0.0 == t }) {
            self = hit.1
            return
        }
        let value: Int? = t.hasPrefix("0x") ? Int(t.dropFirst(2), radix: 16) : Int(t)
        guard let value, (0...255).contains(value) else { return nil }
        self.init(rawValue: UInt8(value))
    }

    public var description: String {
        Self.canonical[rawValue] ?? "0x" + String(format: "%02X", rawValue)
    }
}
