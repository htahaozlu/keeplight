import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore

private let del = AVServiceDiscovery.pnpCode("DEL")!

@Test func fingerprintBaseFormat() {
    #expect(Fingerprint.base(vendorID: del, productID: 0xA0F3, serialNumber: 42, serialString: "4C3V2K3")
            == "DEL:A0F3:4C3V2K3")
    #expect(Fingerprint.base(vendorID: del, productID: 0x12, serialNumber: 42, serialString: nil) == "DEL:0012:42")
    #expect(Fingerprint.base(vendorID: del, productID: 0x12, serialNumber: 42, serialString: "  ") == "DEL:0012:42")
    #expect(Fingerprint.base(vendorID: del, productID: 1, serialNumber: 0, serialString: "A:B") == "DEL:0001:A-B")
    #expect(Fingerprint.base(vendorID: 0, productID: 0, serialNumber: 7, serialString: "X") == nil)
    #expect(Fingerprint.vendorCode(0x0610) == "APP")
    #expect(Fingerprint.vendorCode(0xFFFF) == "0xFFFF")
}

@Test func fingerprintDisambiguatesTwins() {
    let twinA = Fingerprint.Input(displayID: 10, vendorID: del, productID: 0xA0F3, serialNumber: 0, uuid: "UUID-A")
    let twinB = Fingerprint.Input(displayID: 11, vendorID: del, productID: 0xA0F3, serialNumber: 0, uuid: "UUID-B")
    let other = Fingerprint.Input(displayID: 12, vendorID: del, productID: 0xA0F3, serialNumber: 0,
                                  serialString: "SN1", uuid: "UUID-C")
    let virtual = Fingerprint.Input(displayID: 13, vendorID: 0, productID: 0, serialNumber: 0, uuid: "UUID-V")
    var asked: [CGDirectDisplayID] = []
    let locations: [CGDirectDisplayID: String] = [10: "IOService:/a/dispext0@8000000/AppleCLCD2",
                                                  11: "IOService:/a/dispext1@9000000/AppleCLCD2"]
    let fps = Fingerprint.assign([twinA, twinB, other, virtual]) { id in
        asked.append(id)
        return locations[id]
    }
    #expect(asked.sorted() == [10, 11])  // location is only read for duplicates or serial-less displays
    #expect(fps[10] == "DEL:A0F3:0:" + Fingerprint.shortHash(locations[10]!))
    #expect(fps[11] == "DEL:A0F3:0:" + Fingerprint.shortHash(locations[11]!))
    #expect(fps[10] != fps[11])
    #expect(fps[12] == "DEL:A0F3:SN1")
    #expect(fps[13] == "UUID-V")

    // No location: fall back to the CG UUID.
    let noLocation = Fingerprint.assign([twinA, twinB]) { _ in nil }
    #expect(noLocation[10] == "UUID-A" && noLocation[11] == "UUID-B")
    // Alone, a serial-less display keeps the same identity it had beside its twin.
    #expect(Fingerprint.assign([twinA]) { locations[$0] }[10] == fps[10])
    // Alone and without a location, it keeps the plain triple rather than a per-boot UUID.
    #expect(Fingerprint.assign([twinA]) { _ in nil }[10] == "DEL:A0F3:0")
    // A display with a real serial never needs its location.
    #expect(Fingerprint.assign([other]) { _ in "x" }[12] == "DEL:A0F3:SN1")
}

@Test func shortHashIsStable() {
    #expect(Fingerprint.shortHash("") == "811c9d")  // FNV-1a offset basis
    #expect(Fingerprint.shortHash("a") == "e40c29")
    #expect(Fingerprint.shortHash("IOService:/x").count == 6)
}

@Test func displayInfoDefaultsToTripleFingerprint() {
    let d = DisplayInfo(id: 7, name: "U2723QE", vendorID: del, productID: 0x4242, serialNumber: 99, uuid: "U",
                        isBuiltin: false, isMain: false, isActive: true, isOnline: true, mirrorSource: nil,
                        bounds: .zero, rotation: 0, currentMode: nil)
    #expect(d.fingerprint == "DEL:4242:99")
    #expect(d.ref == DisplayRef(name: "U2723QE", fp: "DEL:4242:99"))
}

@Test func placeholderSerialsCarryTheLocation() {
    for serial: UInt32 in [0, 0x0101_0101, 0xFFFF_FFFF] {
        let only = Fingerprint.assign([Fingerprint.Input(displayID: 5, vendorID: 0x10AC, productID: 0xA0F3, serialNumber: serial)],
                                      location: { _ in "IOService:/a/dispext0@8000000/AppleCLCD2" })
        #expect(only[5]?.split(separator: ":").count == 4)
    }
    let real = Fingerprint.assign([Fingerprint.Input(displayID: 5, vendorID: 0x10AC, productID: 0xA0F3, serialNumber: 0x004C_3B21)],
                                  location: { _ in "x" })
    #expect(real[5]?.split(separator: ":").count == 3)
}
