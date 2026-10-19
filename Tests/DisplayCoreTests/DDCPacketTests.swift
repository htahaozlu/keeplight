import Foundation
import Testing
@testable import DisplayCore

private func xor(_ bytes: [UInt8], seed: UInt8) -> UInt8 { bytes.reduce(seed, ^) }

@Test func setVCPEncoding() {
    let p = DDCPacket.setVCP(.brightness, value: 0x0032)
    let body: [UInt8] = [0x84, 0x03, 0x10, 0x00, 0x32]
    #expect(p == body + [xor(body, seed: 0x6E ^ 0x51)])
    #expect(p.last == 0x9A)
    #expect(DDCPacket.setVCP(.volume, value: 0x1234).dropLast() == [0x84, 0x03, 0x62, 0x12, 0x34])
}

@Test func getVCPRequestEncoding() {
    let body: [UInt8] = [0x82, 0x01, 0x10]
    #expect(DDCPacket.getVCPRequest(.brightness) == body + [xor(body, seed: 0x6E ^ 0x51)])
}

private func reply(vcp: UInt8 = 0x10, result: UInt8 = 0, max: UInt16 = 100, cur: UInt16 = 42,
                   lead: Bool = true) -> [UInt8] {
    let frame: [UInt8] = [0x6E, 0x88, 0x02, result, vcp, 0x00,
                          UInt8(max >> 8), UInt8(max & 0xFF), UInt8(cur >> 8), UInt8(cur & 0xFF)]
    let full = frame + [xor(frame, seed: 0x50)]
    return lead ? full : Array(full.dropFirst())
}

@Test func parsesReplyWithLeadingSource() throws {
    let r = try DDCPacket.parseGetVCPReply(reply(), for: .brightness)
    #expect(r.current == 42 && r.maximum == 100)
}

@Test func parsesReplyWithoutLeadingSource() throws {
    let r = try DDCPacket.parseGetVCPReply(reply(max: 0x0190, cur: 0x0101, lead: false), for: .brightness)
    #expect(r.current == 0x0101 && r.maximum == 0x0190)
}

@Test func parsesReplyWithTrailingJunk() throws {
    let r = try DDCPacket.parseGetVCPReply(reply() + [0xFF, 0x00, 0x13], for: .brightness)
    #expect(r.current == 42 && r.maximum == 100)
}

@Test func rejectsBadChecksum() {
    var bad = reply()
    bad[bad.count - 1] ^= 0xFF
    #expect(throws: DisplayError.self) { try DDCPacket.parseGetVCPReply(bad, for: .brightness) }
}

@Test func reportsUnsupportedVCP() {
    do {
        _ = try DDCPacket.parseGetVCPReply(reply(result: 1), for: .brightness)
        Issue.record("expected throw")
    } catch let DisplayError.ddc(message) {
        #expect(message == "unsupported VCP 0x10")
    } catch {
        Issue.record("wrong error \(error)")
    }
}

@Test func rejectsMalformedAndMismatched() {
    #expect(throws: DisplayError.self) { try DDCPacket.parseGetVCPReply([], for: .brightness) }
    #expect(throws: DisplayError.self) { try DDCPacket.parseGetVCPReply([0x6E, 0x88, 0x02], for: .brightness) }
    #expect(throws: DisplayError.self) { try DDCPacket.parseGetVCPReply(reply(vcp: 0x12), for: .brightness) }
}

@Test func vcpNameParsing() {
    #expect(VCP(name: "brightness") == .brightness)
    #expect(VCP(name: "Input") == .inputSource)
    #expect(VCP(name: "inputSource") == .inputSource)
    #expect(VCP(name: "power") == .powerMode)
    #expect(VCP(name: "blueGain") == .blueGain)
    #expect(VCP(name: "factoryReset") == .factoryReset)
    #expect(VCP(name: "0x10") == .brightness)
    #expect(VCP(name: "16") == .brightness)
    #expect(VCP(name: "0xFF")?.rawValue == 0xFF)
    #expect(VCP(name: "256") == nil)
    #expect(VCP(name: "bogus") == nil)
    #expect(VCP.brightness.description == "brightness")
    #expect(VCP(rawValue: 0xE1).description == "0xE1")
    #expect(VCP(rawValue: 0x05).description == "0x05")
}

@Test func liveReadOnly() throws {
    guard ProcessInfo.processInfo.environment["KEEPLIGHT_LIVE"] == "1" else { return }
    for display in DisplayManager.displays() {
        guard let ddc = DDCService(display: display) else {
            print("DDC \(display.name): no service")
            continue
        }
        let r = try? ddc.read(.brightness)
        print("DDC \(display.name): brightness \(String(describing: r))")
    }
    print("services: \(DDCService.serviceSummaries())")
}

@Test func verifiesChecksumWithoutLeadingSource() {
    var bad = reply(lead: false)
    bad[bad.count - 1] ^= 0x01
    #expect(throws: DisplayError.self) { try DDCPacket.parseGetVCPReply(bad, for: .brightness) }
    #expect(throws: DisplayError.self) { try DDCPacket.parseGetVCPReply(Array(reply().dropLast()), for: .brightness) }
}
