#if DEBUG
import AppKit
import DisplayCore
@testable import KeeplightUI

/// Synthetic desks. Values mirror a 14" MacBook Pro with a DDC-capable 27" 4K monitor and a 4K
/// TV/monitor that does not answer DDC/CI.
enum Desk {
    enum Kind: String {
        /// The built-in panel only (Apple brightness).
        case single
        /// Built-in, DELL (main, DDC) and LG (no brightness control).
        case three
        /// Like `three`, the LG mirroring the DELL (inactive, like a hardware mirror target).
        case mirror
        /// The owner's desk: a MacBook closed (clamshell) on one external 4K monitor with DDC/CI.
        case clamshell
    }

    static func mode(_ number: Int32, _ w: Int, _ h: Int, hz: Double = 60, density: Double,
                     flags: UInt32 = 0x1) -> DisplayMode {
        DisplayMode(modeNumber: number, width: w, height: h, refreshRate: hz, depth: 8, density: density, flags: flags)
    }

    static func displays(_ kind: Kind) -> [FakeDisplay] {
        switch kind {
        case .single: [builtin(main: true, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))]
        case .three: [builtin(main: false), dell(), lg(mirroring: nil)]
        case .mirror: [builtin(main: false), dell(), lg(mirroring: 2)]
        case .clamshell: [benq()]
        }
    }

    static func benq() -> FakeDisplay {
        let modes = [mode(31, 3840, 2160, density: 1, flags: 0x5), mode(32, 1920, 1080, density: 2),
                     mode(33, 2560, 1440, density: 2), mode(34, 3008, 1692, density: 2),
                     mode(35, 3360, 1890, density: 2), mode(36, 1920, 1080, density: 1),
                     mode(37, 2560, 1440, density: 1), mode(38, 3840, 2160, hz: 30, density: 1)]
        let info = DisplayInfo(id: 5, name: "BenQ EW3270U", vendorID: 0x09D1, productID: 0x8053, serialNumber: 0x5A31,
                               uuid: nil, isBuiltin: false, isMain: true, isActive: true, isOnline: true,
                               mirrorSource: nil, bounds: CGRect(x: 0, y: 0, width: 3840, height: 2160), rotation: 0,
                               currentMode: modes[0], fingerprint: "RENDER:09D1:8053:BENQ")
        let facts = DiagnosticFacts(connection: .direct, isIntel: false, hardwareModel: "Mac15,6",
                                    appleBrightness: false, ddcChannel: true, ddcReply: .max(100))
        return FakeDisplay(info: info, modes: modes, native: (3840, 2160), backend: .ddc, level: 0.72,
                           edid: FakeEDID.make(vendor: "BNQ", product: 0x8053, serial: "ETK9L01234SL0", week: 18,
                                               year: 2022, widthCM: 70, heightCM: 39, name: "BenQ EW3270U",
                                               native: (3840, 2160)),
                           report: FakeReports.make(for: info, facts: facts, steps: [
                               ("Connection", .observed, "Direct (framebuffer)"),
                               ("Mac", .observed, "Mac15,6 · Apple silicon"),
                               ("Apple brightness", .notAvailable, "—"),
                               ("DDC channel", .observed, "IOAVService found"),
                               ("DDC reply", .observed, "max 100 · current 72"),
                               ("EDID", .observed, "1.4, checksum ok"),
                           ]))
    }

    static let builtinName = "Built-in Liquid Retina XDR Display"

    static func builtin(main: Bool, bounds: CGRect = CGRect(x: -1512, y: 458, width: 1512, height: 982)) -> FakeDisplay {
        let modes = [mode(1, 1512, 982, hz: 120, density: 2, flags: 0x5), mode(2, 1352, 878, hz: 120, density: 2),
                     mode(3, 1800, 1169, hz: 120, density: 2), mode(4, 1147, 745, hz: 120, density: 2),
                     mode(5, 1512, 982, hz: 60, density: 2), mode(6, 3024, 1964, hz: 120, density: 1)]
        let info = DisplayInfo(id: 1, name: builtinName, vendorID: 0x610, productID: 0xA050, serialNumber: 0,
                               uuid: nil, isBuiltin: true, isMain: main, isActive: true, isOnline: true,
                               mirrorSource: nil, bounds: bounds, rotation: 0, currentMode: modes[0],
                               fingerprint: "RENDER:610:A050:builtin")
        let facts = DiagnosticFacts(connection: .builtin, isIntel: false, hardwareModel: "Mac15,6",
                                    appleBrightness: true, ddcChannel: nil, ddcReply: .notTested)
        return FakeDisplay(info: info, modes: modes, native: (3024, 1964), backend: .apple, level: 0.72,
                           edid: nil, report: FakeReports.make(for: info, facts: facts, steps: [
                               ("Connection", .observed, "Built-in"), ("Mac", .observed, "Mac15,6 · Apple silicon"),
                               ("Apple brightness", .observed, "DisplayServices · level 72%"),
                               ("DDC channel", .notTested, "Built-in panels have no DDC/CI"),
                               ("DDC reply", .notTested, "—"), ("EDID", .notAvailable, "Not readable"),
                           ]))
    }

    static func dell() -> FakeDisplay {
        let modes = [mode(11, 1920, 1080, density: 2, flags: 0x5), mode(12, 2560, 1440, density: 2),
                     mode(13, 3008, 1692, density: 2), mode(14, 3840, 2160, density: 1),
                     mode(15, 1920, 1080, density: 1), mode(16, 2560, 1440, density: 1),
                     mode(17, 2560, 1440, hz: 30, density: 1), mode(18, 1280, 720, density: 1, flags: 0),
                     mode(19, 1600, 900, density: 2), mode(20, 3200, 1800, density: 2)]
        let info = DisplayInfo(id: 2, name: "DELL U2723QE", vendorID: 0x10AC, productID: 0xA0F3, serialNumber: 0x4C3B,
                               uuid: nil, isBuiltin: false, isMain: true, isActive: true, isOnline: true,
                               mirrorSource: nil, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), rotation: 0,
                               currentMode: modes[1], fingerprint: "RENDER:10AC:A0F3:DELL")
        let facts = DiagnosticFacts(connection: .direct, isIntel: false, hardwareModel: "Mac15,6",
                                    appleBrightness: false, ddcChannel: true, ddcReply: .max(100))
        return FakeDisplay(info: info, modes: modes, native: (3840, 2160), backend: .ddc, level: 0.40,
                           edid: FakeEDID.make(vendor: "DEL", product: 0xA0F3, serial: "8JK3TP3", week: 34, year: 2023,
                                               widthCM: 60, heightCM: 34, name: "DELL U2723QE",
                                               native: (3840, 2160)),
                           report: FakeReports.make(for: info, facts: facts, steps: [
                               ("Connection", .observed, "Direct (framebuffer)"),
                               ("Mac", .observed, "Mac15,6 · Apple silicon"),
                               ("Apple brightness", .notAvailable, "—"),
                               ("DDC channel", .observed, "IOAVService found"),
                               ("DDC reply", .observed, "max 100 · current 40"),
                               ("EDID", .observed, "1.4, checksum ok"),
                           ]))
    }

    static func lg(mirroring source: CGDirectDisplayID?) -> FakeDisplay {
        let modes = [mode(21, 1920, 1080, density: 1), mode(22, 3840, 2160, hz: 30, density: 1),
                     mode(23, 1280, 720, density: 1), mode(24, 1920, 1080, density: 2),
                     mode(25, 2560, 1440, density: 2), mode(26, 3840, 2160, density: 1)]
        let mirrored = source != nil
        let info = DisplayInfo(id: 3, name: "LG HDR 4K", vendorID: 0x1E6D, productID: 0x5B9C, serialNumber: 0x1D2E,
                               uuid: nil, isBuiltin: false, isMain: false, isActive: !mirrored, isOnline: true,
                               mirrorSource: source,
                               bounds: mirrored ? CGRect(x: 0, y: 0, width: 2560, height: 1440)
                                   : CGRect(x: 2560, y: 120, width: 1920, height: 1080),
                               rotation: 0, currentMode: modes[0], fingerprint: "RENDER:1E6D:5B9C:LG")
        let facts = DiagnosticFacts(connection: .direct, isIntel: false, hardwareModel: "Mac15,6",
                                    appleBrightness: false, ddcChannel: true, ddcReply: .noReply)
        return FakeDisplay(info: info, modes: modes, native: (3840, 2160), backend: nil, level: 0,
                           edid: FakeEDID.make(vendor: "GSM", product: 0x5B9C, serial: "105NTAB2X417", week: 12,
                                               year: 2021, widthCM: 60, heightCM: 34, name: "LG HDR 4K",
                                               native: (3840, 2160)),
                           report: FakeReports.make(for: info, facts: facts, steps: [
                               ("Connection", .observed, "Direct (framebuffer)"),
                               ("Mac", .observed, "Mac15,6 · Apple silicon"),
                               ("Apple brightness", .notAvailable, "—"),
                               ("DDC channel", .observed, "IOAVService found"),
                               ("DDC reply", .noReply, "no reply after 4 tries"),
                               ("EDID", .observed, "1.4, checksum ok"),
                           ]))
    }

    /// A display Keeplight disconnected (shown in the panel's Disconnected section).
    static let samsung = DisconnectedDisplay(fingerprint: "RENDER:4C2D:7179:SAMSUNG", displayID: 4,
                                             name: "Samsung Odyssey G7", disconnectedAt: Date(timeIntervalSince1970: 0))
}

/// Valid EDID 1.4 base blocks, so the passport shows made / size / identity like a real monitor.
enum FakeEDID {
    static func make(vendor: String, product: UInt16, serial: String, week: Int, year: Int, widthCM: Int,
                     heightCM: Int, name: String, native: (Int, Int)) -> EDID? {
        var b = [UInt8](repeating: 0, count: 128)
        b[0..<8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        let letters = vendor.utf8.map { Int($0) - 64 }
        let m = letters[0] << 10 | letters[1] << 5 | letters[2]
        b[8] = UInt8(m >> 8)
        b[9] = UInt8(m & 0xFF)
        b[10] = UInt8(product & 0xFF)
        b[11] = UInt8(product >> 8)
        b[16] = UInt8(week)
        b[17] = UInt8(year - 1990)
        b[18] = 1
        b[19] = 4
        b[21] = UInt8(widthCM)
        b[22] = UInt8(heightCM)
        // Detailed timing: 594 MHz, native active pixels, small blanking.
        let clock = 59_400
        let (hA, vA, hB, vB) = (native.0, native.1, 560, 90)
        var t = [UInt8](repeating: 0, count: 18)
        t[0] = UInt8(clock & 0xFF)
        t[1] = UInt8(clock >> 8)
        t[2] = UInt8(hA & 0xFF)
        t[3] = UInt8(hB & 0xFF)
        t[4] = UInt8((hA >> 8) << 4 | (hB >> 8))
        t[5] = UInt8(vA & 0xFF)
        t[6] = UInt8(vB & 0xFF)
        t[7] = UInt8((vA >> 8) << 4 | (vB >> 8))
        b[54..<72] = t[0..<18]
        b[72..<90] = descriptor(0xFF, serial)[0..<18]
        b[90..<108] = descriptor(0xFC, name)[0..<18]
        b[108..<126] = descriptor(0x10, "")[0..<18]
        b[127] = UInt8((256 - b[0..<127].reduce(0) { ($0 + Int($1)) % 256 }) % 256)
        return try? EDID(data: Data(b))
    }

    private static func descriptor(_ tag: UInt8, _ text: String) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 18)
        d[3] = tag
        var bytes = Array(text.utf8.prefix(13))
        if bytes.count < 13 { bytes.append(0x0A) }
        while bytes.count < 13 { bytes.append(0x20) }
        d[5..<18] = bytes[0..<13]
        return d
    }
}

/// `DiagnosticReport` has no public memberwise init; it is Codable, so reports are decoded.
enum FakeReports {
    static let virtualFacts = DiagnosticFacts(connection: .virtual, isIntel: false, hardwareModel: "Mac15,6",
                                              appleBrightness: false, ddcChannel: nil, ddcReply: .notTested)

    private struct Wire: Encodable {
        var display: String
        var fingerprint: String
        var steps: [DiagnosticStep]
        var verdict: String
        var facts: DiagnosticFacts
        var hardwareModel = "Mac15,6"
        var architecture = "arm64"
        var macOS = "26.5 (25F71)"
        var edid: String?
        var serial: String?
        var keeplightVersion = Keeplight.version
        var generatedAt = Date(timeIntervalSinceReferenceDate: 0)
    }

    static func make(for info: DisplayInfo, facts: DiagnosticFacts,
                     steps: [(String, DiagnosticGrade, String)] = []) -> DiagnosticReport {
        let wire = Wire(display: info.name, fingerprint: Diagnostics.redactFingerprint(info.fingerprint),
                        steps: steps.map { DiagnosticStep(name: $0.0, grade: $0.1, detail: $0.2, ms: 3) },
                        verdict: Diagnostics.verdict(for: facts), facts: facts)
        // Encoder and decoder share the default strategies, so the round trip is exact.
        let data = try! JSONEncoder().encode(wire)
        return try! JSONDecoder().decode(DiagnosticReport.self, from: data)
    }
}
#endif
