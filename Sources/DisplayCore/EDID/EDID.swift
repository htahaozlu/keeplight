import CoreGraphics
import Foundation
import IOKit

/// VESA E-EDID 1.3/1.4 base block (128 bytes); extension blocks are counted, not decoded.
public struct EDID: Hashable, Sendable {
    public struct DetailedTiming: Hashable, Sendable {
        public let pixelClockKHz: Int
        public let horizontalActive: Int
        public let verticalActive: Int
        public let refreshRate: Double
    }

    public let raw: Data
    /// Three-letter PNP ID, e.g. `DEL`.
    public let manufacturerID: String
    public let productCode: UInt16
    public let serialNumber: UInt32
    public let manufactureWeek: Int
    public let manufactureYear: Int
    public let version: Int
    public let revision: Int
    /// Physical size in centimeters (0 when undefined).
    public let widthCM: Int
    public let heightCM: Int
    public let displayName: String?
    public let serialString: String?
    public let preferredTiming: DetailedTiming?
    public let extensionCount: Int
    public let checksumValid: Bool

    public init(data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 128 else { throw DisplayError.invalidArgument("EDID needs at least 128 bytes, got \(b.count)") }
        guard Array(b[0..<8]) == [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00] else {
            throw DisplayError.invalidArgument("EDID header mismatch")
        }
        raw = data
        let m = Int(b[8]) << 8 | Int(b[9])
        let letters = [(m >> 10) & 31, (m >> 5) & 31, m & 31].map { UInt8($0 + 64) }
        manufacturerID = String(decoding: letters, as: UTF8.self)
        productCode = UInt16(b[10]) | UInt16(b[11]) << 8
        serialNumber = UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24
        manufactureWeek = Int(b[16])
        manufactureYear = Int(b[17]) + 1990
        version = Int(b[18])
        revision = Int(b[19])
        widthCM = Int(b[21])
        heightCM = Int(b[22])
        extensionCount = Int(b[126])
        checksumValid = b[0..<128].reduce(0) { $0 &+ Int($1) } % 256 == 0

        var name: String?
        var serial: String?
        var timing: DetailedTiming?
        for offset in [54, 72, 90, 108] {
            let d = Array(b[offset..<offset + 18])
            if d[0] != 0 || d[1] != 0 {
                if timing == nil { timing = Self.timing(d) }
                continue
            }
            switch d[3] {
            case 0xFC: name = Self.text(d)
            case 0xFF: serial = Self.text(d)
            default: break
            }
        }
        displayName = name
        serialString = serial
        preferredTiming = timing
    }

    private static func timing(_ d: [UInt8]) -> DetailedTiming? {
        let clock = Int(d[0]) | Int(d[1]) << 8
        let hA = Int(d[2]) | (Int(d[4]) & 0xF0) << 4
        let hB = Int(d[3]) | (Int(d[4]) & 0x0F) << 8
        let vA = Int(d[5]) | (Int(d[7]) & 0xF0) << 4
        let vB = Int(d[6]) | (Int(d[7]) & 0x0F) << 8
        let total = (hA + hB) * (vA + vB)
        return DetailedTiming(pixelClockKHz: clock * 10, horizontalActive: hA, verticalActive: vA,
                              refreshRate: total > 0 ? Double(clock) * 10_000 / Double(total) : 0)
    }

    private static func text(_ d: [UInt8]) -> String {
        let bytes = d[5..<18].prefix { $0 != 0x0A }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads the EDID of an online display from the IORegistry; nil when unavailable.
    public static func read(for display: DisplayInfo) -> EDID? {
        #if !arch(x86_64)
        if let copyEDID = PrivateSymbols.ioAVServiceCopyEDID,
           let entry = AVServiceDiscovery.match(display, in: AVServiceDiscovery.entries()) {
            var data: UnsafeRawPointer?
            let rc = withExtendedLifetime(entry.service) { copyEDID(DDCService.handle(entry.service), &data) }
            if rc == KERN_SUCCESS, let data {
                let cf = Unmanaged<CFData>.fromOpaque(data).takeRetainedValue()
                if let edid = try? EDID(data: cf as Data) { return edid }
            }
        }
        #endif
        return registryEDID(for: display)
    }

    private static func registryEDID(for display: DisplayInfo) -> EDID? {
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var candidates: [EDID] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let data = AVServiceDiscovery.property(entry, "IODisplayEDID") as? Data,
                  let edid = try? EDID(data: data),
                  AVServiceDiscovery.pnpCode(edid.manufacturerID) == display.vendorID,
                  UInt32(edid.productCode) == display.productID else { continue }
            candidates.append(edid)
        }
        return candidates.first { $0.serialNumber == display.serialNumber } ?? candidates.first
    }
}
