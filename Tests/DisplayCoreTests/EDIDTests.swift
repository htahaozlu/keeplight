import Foundation
import Testing
@testable import DisplayCore

private func makeEDID(manufacturer: String = "DEL", product: UInt16 = 0xA0B1, serial: UInt32 = 0x01020304,
                      extensions: UInt8 = 1) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 128)
    b.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    let l = manufacturer.utf8.map { Int($0) - 64 }
    let m = l[0] << 10 | l[1] << 5 | l[2]
    b[8] = UInt8(m >> 8); b[9] = UInt8(m & 0xFF)
    b[10] = UInt8(product & 0xFF); b[11] = UInt8(product >> 8)
    for i in 0..<4 { b[12 + i] = UInt8((serial >> (8 * UInt32(i))) & 0xFF) }
    b[16] = 12; b[17] = 33; b[18] = 1; b[19] = 4
    b[21] = 60; b[22] = 34

    // 3840x2160, 533.25 MHz, hBlank 160, vBlank 62
    let clock = 53325, hA = 3840, hB = 160, vA = 2160, vB = 62
    b[54] = UInt8(clock & 0xFF); b[55] = UInt8(clock >> 8)
    b[56] = UInt8(hA & 0xFF); b[57] = UInt8(hB & 0xFF); b[58] = UInt8((hA >> 8) << 4 | (hB >> 8))
    b[59] = UInt8(vA & 0xFF); b[60] = UInt8(vB & 0xFF); b[61] = UInt8((vA >> 8) << 4 | (vB >> 8))

    func text(_ tag: UInt8, _ s: String, at o: Int) {
        b[o + 3] = tag
        var bytes = Array(s.utf8) + [0x0A]
        while bytes.count < 13 { bytes.append(0x20) }
        b.replaceSubrange(o + 5..<o + 18, with: bytes)
    }
    text(0xFF, "ABC123", at: 72)
    text(0xFC, "DELL U2723QE", at: 90)

    b[126] = extensions
    b[127] = 0
    b[127] = UInt8((256 - b[0..<127].reduce(0) { ($0 + Int($1)) % 256 }) % 256)
    return b
}

@Test func parsesSyntheticEDID() throws {
    let bytes = makeEDID()
    let e = try EDID(data: Data(bytes))
    #expect(e.manufacturerID == "DEL")
    #expect(e.productCode == 0xA0B1)
    #expect(e.serialNumber == 0x01020304)
    #expect(e.manufactureWeek == 12 && e.manufactureYear == 2023)
    #expect(e.version == 1 && e.revision == 4)
    #expect(e.widthCM == 60 && e.heightCM == 34)
    #expect(e.displayName == "DELL U2723QE")
    #expect(e.serialString == "ABC123")
    #expect(e.extensionCount == 1)
    #expect(e.checksumValid)
    #expect(e.raw == Data(bytes))
    let t = try #require(e.preferredTiming)
    #expect(t.pixelClockKHz == 533_250)
    #expect(t.horizontalActive == 3840 && t.verticalActive == 2160)
    #expect(abs(t.refreshRate - 60) < 0.05)
}

@Test func detectsBadChecksumAndKeepsExtraBytes() throws {
    var bytes = makeEDID()
    bytes[127] &+= 1
    bytes += [UInt8](repeating: 0xAA, count: 128)
    let e = try EDID(data: Data(bytes))
    #expect(!e.checksumValid)
    #expect(e.raw.count == 256)
}

@Test func rejectsBadInput() {
    var bytes = makeEDID()
    bytes[1] = 0
    #expect(throws: DisplayError.self) { try EDID(data: Data(bytes)) }
    #expect(throws: DisplayError.self) { try EDID(data: Data(makeEDID().prefix(127))) }
}

@Test func pnpCodeMatchesManufacturer() {
    #expect(AVServiceDiscovery.pnpCode("DEL") == UInt32(4) << 10 | 5 << 5 | 12)
    #expect(AVServiceDiscovery.pnpCode("de") == nil)
}
