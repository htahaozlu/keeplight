import Testing
@testable import DisplayCore

@Test func modeSpecParses() throws {
    let s = try ModeSpec("2560x1440@120 hidpi")
    #expect(s.width == 2560 && s.height == 1440 && s.refreshRate == 120 && s.hiDPI == true)
    let plain = try ModeSpec("1920x1080")
    #expect(plain.refreshRate == nil && plain.hiDPI == nil)
    #expect(try ModeSpec("1920x1080@59.94 lodpi").hiDPI == false)
}

@Test(arguments: ["", "1920x1080@", "1920xfoox1080", "1920x1080x", "x1080", "1920x", "0x1080",
                  "1920x1080@60@60", "1920x1080@-60", "1920x1080 retina"])
func modeSpecRejects(_ text: String) {
    #expect(throws: DisplayError.self) { try ModeSpec(text) }
}

private func mode(_ n: Int32, _ w: Int, _ h: Int, hz: Double = 60, density: Double = 1,
                  depth: Int = 8, flags: UInt32 = 0x1) -> DisplayMode {
    DisplayMode(modeNumber: n, width: w, height: h, refreshRate: hz, depth: depth, density: density, flags: flags)
}

@Test func uniqueModesFiltersAndOrders() {
    let modes = [
        mode(1, 1920, 1080),
        mode(2, 1920, 1080, flags: 0x4000_0000),  // same label, not usable
        mode(3, 1920, 1080, density: 2),
        mode(4, 2560, 1440),
        mode(5, 640, 480, flags: 0x4000_0000),    // only unusable variant
        mode(6, 2560, 1440, depth: 10),
        mode(7, 1920, 1080, hz: 50),
    ]
    let unique = DisplayManager.uniqueModes(modes, current: nil)
    #expect(unique.map(\.modeNumber) == [3, 6, 1, 7])
}

@Test func uniqueModesKeepsCurrent() {
    let modes = [mode(1, 1920, 1080), mode(2, 1920, 1080, depth: 10), mode(9, 800, 600, flags: 0x4000_0000)]
    #expect(DisplayManager.uniqueModes(modes, current: modes[0]).map(\.modeNumber) == [1])
    #expect(DisplayManager.uniqueModes(modes, current: modes[2]).map(\.modeNumber) == [2, 9])
}
