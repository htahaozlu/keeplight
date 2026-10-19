#if DEBUG
import AppKit
import DisplayCore

/// Debug previews (`KEEPLIGHT_DEBUG_PANEL=1` with `KEEPLIGHT_DEBUG_STATE=fake,…`): a synthetic desk
/// so multi-display layouts can be checked on a one-display Mac. Nothing here is ever written.
struct DebugBrightness: BrightnessControl {
    let displayID: CGDirectDisplayID
    let backend: BrightnessBackend
    let level: Double

    func brightness() throws -> Double { level }
    func setBrightness(_ value: Double) throws {}
}

extension AppModel {
    /// Three displays: a built-in panel, a main DDC monitor and one without brightness control
    /// (state `mirror`: that one mirrors the DELL, inactive like a hardware mirror target).
    func installFakeDisplays() {
        fakeDisplays = true
        let mirrored = flags.debugStates["mirror"] != nil
        func mode(_ number: Int32, _ w: Int, _ h: Int, hz: Double, density: Double, flags: UInt32 = 0x1) -> DisplayMode {
            DisplayMode(modeNumber: number, width: w, height: h, refreshRate: hz, depth: 8, density: density, flags: flags)
        }
        func info(_ id: UInt32, _ name: String, vendor: UInt32, product: UInt32, builtin: Bool, main: Bool,
                  bounds: CGRect, current: DisplayMode, mirrorSource: UInt32? = nil) -> DisplayInfo {
            DisplayInfo(id: id, name: name, vendorID: vendor, productID: product, serialNumber: id, uuid: nil,
                        isBuiltin: builtin, isMain: main, isActive: mirrorSource == nil, isOnline: true,
                        mirrorSource: mirrorSource, bounds: bounds, rotation: 0, currentMode: current,
                        fingerprint: "FAKE:\(id)")
        }
        let builtinModes = [mode(1, 1512, 982, hz: 120, density: 2, flags: 0x5), mode(2, 1352, 878, hz: 120, density: 2),
                            mode(3, 1800, 1169, hz: 120, density: 2), mode(4, 1147, 745, hz: 120, density: 2),
                            mode(5, 1512, 982, hz: 60, density: 2), mode(6, 3024, 1964, hz: 120, density: 1)]
        let dellModes = [mode(11, 1920, 1080, hz: 60, density: 2, flags: 0x5), mode(12, 2560, 1440, hz: 60, density: 2),
                         mode(13, 3008, 1692, hz: 60, density: 2), mode(14, 3840, 2160, hz: 60, density: 1),
                         mode(15, 1920, 1080, hz: 60, density: 1), mode(16, 2560, 1440, hz: 60, density: 1),
                         mode(17, 2560, 1440, hz: 30, density: 1), mode(18, 1280, 720, hz: 60, density: 1, flags: 0)]
        // Current mode SOFT; the ring preview targets the NATIVE 3840 × 2160.
        let lgModes = [mode(21, 1920, 1080, hz: 60, density: 1), mode(22, 3840, 2160, hz: 30, density: 1),
                       mode(23, 1280, 720, hz: 60, density: 1), mode(24, 1920, 1080, hz: 60, density: 2),
                       mode(25, 2560, 1440, hz: 60, density: 2), mode(26, 3840, 2160, hz: 60, density: 1)]
        let builtin = info(1001, "Built-in Retina Display", vendor: 0x610, product: 0xA050, builtin: true, main: false,
                           bounds: CGRect(x: -1512, y: 458, width: 1512, height: 982), current: builtinModes[0])
        let dell = info(1002, "DELL U2723QE", vendor: 0x10AC, product: 0xA0F3, builtin: false, main: true,
                        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), current: dellModes[1])
        let lg = info(1003, "LG HDR 4K", vendor: 0x1E6D, product: 0x5B9C, builtin: false, main: false,
                      bounds: mirrored ? dell.bounds : CGRect(x: 2560, y: 120, width: 1920, height: 1080),
                      current: lgModes[0], mirrorSource: mirrored ? dell.id : nil)
        let natives: [(DisplayInfo, [DisplayMode], PixelSize)] = [
            (builtin, builtinModes, PixelSize((3024, 1964))),
            (dell, dellModes, PixelSize((3840, 2160))),
            (lg, lgModes, PixelSize((3840, 2160))),
        ]
        items = natives.enumerated().map { offset, entry in
            DisplayItem(info: entry.0, index: offset + 1, modes: entry.1, native: entry.2, isPhysical: true, isNew: false)
        }
        knownIDs = Set(items.map(\.id))
        brightness[1001] = .available(control: DebugBrightness(displayID: 1001, backend: .apple, level: 0.72),
                                      value: 0.72, readMs: 3)
        brightness[1002] = .available(control: DebugBrightness(displayID: 1002, backend: .ddc, level: 0.40),
                                      value: 0.40, readMs: 112)
        brightness[1003] = .unavailable
        let now = Date()
        let dellRef = DisplayRef(name: "DELL U2723QE", fp: "FAKE:1002")
        func entry(_ minutes: Double, _ kind: JournalEntry.Kind, _ before: String, _ after: String,
                   source: JournalEntry.Source = .panel, result: JournalEntry.Outcome = .applied,
                   display: DisplayRef? = nil, reason: String? = nil) -> JournalEntry {
            JournalEntry(t: now.addingTimeInterval(-minutes * 60), source: source, display: display ?? dellRef, kind: kind,
                         before: before, after: after, mechanism: nil, result: result, reason: reason)
        }
        debugJournal = [
            entry(190, .brightness, "100%", "40%", source: .wake, result: .restored),
            entry(120, .mode, "2560x1440@60 hidpi", "3008x1692@60 hidpi", result: .reverted, reason: "timeout"),
            entry(45, .brightness, "40%", "55%"),
            entry(30, .main, "Built-in Retina Display", "DELL U2723QE", result: .kept),
            entry(12, .mode, "1920x1080@60 hidpi", "2560x1440@60 hidpi", result: .kept),
            entry(4, .disconnect, "connected", "disconnected", result: .kept,
                  display: DisplayRef(name: "LG HDR 4K", fp: "FAKE:1003")),
        ]
        if flags.debugStates["disc"] != nil {
            disconnected = [DisconnectedDisplay(fingerprint: "FAKE:2001", displayID: 2001, name: "Samsung Odyssey G7")]
        }
    }

    // MARK: Debug previews

    func applyDebugStates() {
        let states = flags.debugStates
        if let n = states["why"].flatMap(Int.init), items.indices.contains(n - 1) {
            whyExpanded.insert(items[n - 1].id)
            diagnose(items[n - 1].fingerprint)
        }
        if states["firstrun"] != nil { showFirstRun = true }
        if states["identify"] != nil { Task { try? await Task.sleep(for: .milliseconds(500)); shell?.identify() } }
        if states["safestart"] != nil { showSafeStart = true }
        if states["settling"] != nil { isSettling = true }
        if states["receipt"] != nil, let first = items.first {
            showReceipt(Copy.wakeReceipt(name: name(first.info), percent: 40), undo: .entry("debug"))
        }
        if states["ring"] != nil, let item = items.last {
            let now = Date()
            let target = item.recommended.last { $0.modeNumber != item.current?.modeNumber }
            let detail = "\(name(item.info)) · \(item.current?.sizeText ?? "?") → \(target?.sizeText ?? "?")"
            let info = PendingInfo(id: "debug", kind: .mode, displayName: name(item.info),
                                   title: OverlayCopy.keepTitle(.mode, name: name(item.info), summary: detail),
                                   detail: detail,
                                   displayFingerprint: item.fingerprint, before: item.current?.label ?? "",
                                   startedAt: now.addingTimeInterval(-3), deadline: now.addingTimeInterval(27))
            pending = info
            ringInfo = info
            ringPhase = .live
            shell?.showRing()
            armKeep()
        }
        if let appearance = states["appearance"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let tab = states["settings"].flatMap(SettingsTab.init(rawValue:)) {
            settingsSelection = items.last?.fingerprint
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.openSettings(tab: tab)
            }
        }
    }
}
#endif
