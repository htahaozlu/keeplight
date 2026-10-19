import Testing
@testable import DisplayCore

private let uhd = (width: 3840, height: 2160)

@Test func classifiesSharpness() {
    #expect(dmode(1, 1920, 1080, density: 2).sharpness(native: uhd) == .crisp)
    #expect(dmode(2, 2560, 1440, density: 2).sharpness(native: uhd) == .scaled)
    #expect(dmode(3, 1280, 720, density: 2).sharpness(native: uhd) == .scaled)
    #expect(dmode(4, 3840, 2160).sharpness(native: uhd) == .native)
    #expect(dmode(5, 1920, 1080).sharpness(native: uhd) == .soft)
    #expect(dmode(6, 2560, 1440).sharpness(native: uhd) == .soft)
    #expect(Sharpness.crisp.tag == "CRISP")
    #expect(dmode(2, 2560, 1440, density: 2).scale(native: uhd) == 0.75)
}

/// A 4K panel at 60 and 30 Hz, shaped like a real CGS list.
private let uhdModes: [DisplayMode] = [
    dmode(10, 1280, 720, density: 2),
    dmode(11, 1600, 900, density: 2),
    dmode(12, 1920, 1080, density: 2, flags: 0x0200_0007),
    dmode(13, 2304, 1296, density: 2),
    dmode(14, 2560, 1440, density: 2),
    dmode(15, 3008, 1692, density: 2),
    dmode(16, 3360, 1890, density: 2),
    dmode(17, 3840, 2160, flags: 0x0200_0001),
    dmode(18, 1920, 1080),                         // SOFT
    dmode(19, 2560, 1440),                         // SOFT
    dmode(20, 1920, 1080, hz: 30, density: 2),     // other refresh rate
    dmode(21, 2560, 1440, density: 2, depth: 10),  // deeper duplicate of 14
    dmode(22, 1024, 768, density: 2, flags: 0x4000_0000),  // unusable
]

@Test func recommendedModesForUHDPanel() {
    let current = uhdModes[2]  // 1920x1080 HiDPI, CRISP
    let list = DisplayManager.recommendedModes(uhdModes, current: current, native: uhd)
    #expect(list.count == 6)
    // Current + CRISP (same here) + NATIVE, then SCALED nearest to 1920 wide.
    #expect(list.map(\.width) == [1280, 1600, 1920, 2304, 2560, 3840])
    #expect(list.contains { $0.modeNumber == 12 })
    #expect(list.contains { $0.modeNumber == 17 })
    #expect(list.allSatisfy { $0.refreshRate == 60 && $0.sharpness(native: uhd) != .soft })
    // One row per logical size: the deeper 2560x1440 HiDPI wins.
    #expect(list.first { $0.width == 2560 }?.modeNumber == 21)
}

@Test func recommendedModesKeepsCurrentAndRespectsLimit() {
    let soft = uhdModes[8]  // 1920x1080 non-HiDPI
    let list = DisplayManager.recommendedModes(uhdModes, current: soft, native: uhd, limit: 4)
    #expect(list.count == 4)
    #expect(list.contains { $0.modeNumber == soft.modeNumber })     // current, even though SOFT
    #expect(list.contains { $0.modeNumber == 12 })                   // the CRISP twin of the current size stays
    #expect(list.contains { $0.modeNumber == 17 })                   // NATIVE before SCALED
    #expect(list.map(\.width) == list.map(\.width).sorted())

    let thirty = uhdModes.first { $0.modeNumber == 20 }!
    let slow = DisplayManager.recommendedModes(uhdModes, current: thirty, native: uhd)
    #expect(slow.map(\.modeNumber) == [20])  // current refresh rate only
}

@Test func recommendedModesWithoutCurrent() {
    let list = DisplayManager.recommendedModes(uhdModes, current: nil, native: uhd, limit: 3)
    #expect(list.map(\.modeNumber) == [11, 12, 17])  // CRISP, NATIVE, nearest SCALED to the CRISP width
}

@Test func nativePixelSizeFromModes() {
    // The native flag wins over larger "more space" backing stores.
    let n = DisplayManager.nativePixelSize(fromModes: uhdModes)
    #expect(n?.width == 3840 && n?.height == 2160)
    // Without flags: largest non-HiDPI mode, not a 6016-pixel HiDPI backing store.
    let unflagged = [dmode(1, 3008, 1692, density: 2), dmode(2, 2560, 1440), dmode(3, 1920, 1080)]
    #expect(DisplayManager.nativePixelSize(fromModes: unflagged)?.width == 2560)
    #expect(DisplayManager.nativePixelSize(fromModes: [dmode(1, 1512, 982, density: 2)])?.width == 3024)
    #expect(DisplayManager.nativePixelSize(fromModes: []) == nil)
}

@Test func recommendedModesKeepsSharperTwinOfSoftCurrent() {
    let soft = uhdModes.first { $0.modeNumber == 18 }!
    let list = DisplayManager.recommendedModes(uhdModes, current: soft, native: uhd)
    #expect(list.contains { $0.modeNumber == 18 })
    #expect(list.contains { $0.modeNumber == 12 })
    #expect(list.count <= 6)
}

@Test func softCurrentKeepsCrispSibling() {
    let soft = uhdModes.first { $0.modeNumber == 18 }!
    let list = DisplayManager.recommendedModes(uhdModes, current: soft, native: uhd)
    #expect(list.contains { $0.modeNumber == 18 })
    #expect(list.contains { $0.modeNumber == 12 })
}
