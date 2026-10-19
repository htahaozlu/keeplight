#if DEBUG
import AppKit
import DisplayCore
@testable import KeeplightUI

// Fakes for every system-facing seam in `AppServices` / `ShellActions`. Reads answer from a
// synthetic desk; every write, tap, registration or window refuses (throws or no-ops) and is
// logged. The tool exits non-zero when the log is not empty.

/// Every refused call, from any thread.
final class RefusalLog: @unchecked Sendable {
    static let shared = RefusalLog()
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ call: String) {
        lock.lock()
        entries.append(call)
        lock.unlock()
        FileHandle.standardError.write(Data("keeplight-render: REFUSED \(call)\n".utf8))
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

struct Refused: Error, CustomStringConvertible {
    let call: String
    var description: String { "keeplight-render refuses \(call)" }
}

@discardableResult
private func refuse(_ call: String) -> Refused {
    RefusalLog.shared.record(call)
    return Refused(call: call)
}

// MARK: - Displays

/// One synthetic display.
struct FakeDisplay: Sendable {
    var info: DisplayInfo
    var modes: [DisplayMode]
    var native: (width: Int, height: Int)?
    /// nil: no brightness backend.
    var backend: BrightnessBackend?
    var level: Double
    var edid: EDID?
    var report: DiagnosticReport
}

/// Reads come from `displays`; no call reaches CoreGraphics, IOKit, DDC or DisplayServices.
final class FakeDisplaySystem: AppDisplaySystem, @unchecked Sendable {
    let displaysByID: [CGDirectDisplayID: FakeDisplay]
    let order: [CGDirectDisplayID]

    init(_ displays: [FakeDisplay]) {
        order = displays.map(\.info.id)
        displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.info.id, $0) })
    }

    func snapshot() -> DisplaySnapshot {
        DisplaySnapshot(displays: order.compactMap { displaysByID[$0] }.map { d in
            DisplaySnapshot.Entry(fingerprint: d.info.fingerprint, displayID: d.info.id, name: d.info.name,
                                  modeNumber: d.info.currentMode?.modeNumber, modeLabel: d.info.currentMode?.label,
                                  origin: DisplayOrigin(d.info.bounds.origin), isMain: d.info.isMain,
                                  isBuiltin: d.info.isBuiltin)
        })
    }

    func restore(_ snapshot: DisplaySnapshot, option: CGConfigureOption) -> [RestoreStep] {
        refuse("DisplaySystem.restore")
        return []
    }

    func displays() -> [DisplayInfo] { order.compactMap { displaysByID[$0]?.info } }
    func modes(for id: CGDirectDisplayID) -> [DisplayMode] { displaysByID[id]?.modes ?? [] }
    func nativePixelSize(for id: CGDirectDisplayID) -> (width: Int, height: Int)? { displaysByID[id]?.native }
    func isPhysical(_ id: CGDirectDisplayID) -> Bool { displaysByID[id] != nil }

    func setEnabled(_ enabled: Bool, for id: CGDirectDisplayID, option: CGConfigureOption) throws {
        throw refuse("DisplaySystem.setEnabled(\(enabled), \(id))")
    }

    func setMain(_ id: CGDirectDisplayID, option: CGConfigureOption) throws { throw refuse("DisplaySystem.setMain(\(id))") }

    func setMode(_ modeNumber: Int32, for id: CGDirectDisplayID, option: CGConfigureOption) throws {
        throw refuse("DisplaySystem.setMode(\(modeNumber), \(id))")
    }

    func unmirror(_ id: CGDirectDisplayID, option: CGConfigureOption) throws { throw refuse("DisplaySystem.unmirror(\(id))") }

    func mirror(_ target: CGDirectDisplayID, of source: CGDirectDisplayID, option: CGConfigureOption) throws {
        throw refuse("DisplaySystem.mirror(\(target), of: \(source))")
    }

    func execute(_ plan: [RestoreAction], option: CGConfigureOption) -> [RestoreStep] {
        refuse("DisplaySystem.execute(\(plan.count) actions)")
        return plan.map { RestoreStep(action: $0, error: "refused by keeplight-render") }
    }

    func brightnessControl(for display: DisplayInfo) -> (any BrightnessControl)? {
        guard let d = displaysByID[display.id], let backend = d.backend else { return nil }
        return FakeBrightness(displayID: display.id, backend: backend, level: d.level)
    }

    func diagnose(_ display: DisplayInfo) -> DiagnosticReport {
        displaysByID[display.id]?.report ?? FakeReports.make(for: display, facts: FakeReports.virtualFacts)
    }

    func edid(for display: DisplayInfo) -> EDID? { displaysByID[display.id]?.edid }

    /// Never fires: nothing reconfigures.
    func observeReconfiguration(_ handler: @escaping @Sendable () -> Void) -> AnyObject { NSObject() }
}

/// Reads the synthetic level; writing refuses.
struct FakeBrightness: BrightnessControl {
    let displayID: CGDirectDisplayID
    let backend: BrightnessBackend
    let level: Double

    func brightness() throws -> Double { level }
    func setBrightness(_ value: Double) throws { throw refuse("BrightnessControl.setBrightness(\(value), \(displayID))") }
}

// MARK: - Hotkeys, key tap, login item, sleep/wake

@MainActor
final class FakeHotKeys: HotKeyRegistry {
    func register(_ key: HotKeys.Key, onPress: @escaping @MainActor () -> Void,
                  onRelease: (@MainActor () -> Void)?) -> Bool {
        refuse("HotKeys.register(\(key.display))")
        return false
    }

    func unregister(_ key: HotKeys.Key) {}
}

/// Never installs an event tap and never asks for Accessibility. `isRunning` is set by scenarios.
@MainActor
final class FakeKeyTap: BrightnessKeyTap {
    var isRunning = false
    var onChange: (@MainActor () -> Void)?

    func start() -> Bool {
        refuse("BrightnessKeys.start")
        return false
    }

    func requestAndStart() { refuse("BrightnessKeys.requestAndStart (Accessibility prompt)") }
    func waitForTrust() { refuse("BrightnessKeys.waitForTrust") }
    /// Stopping a tap that never started changes nothing.
    func stop() {}
}

struct FakeLoginItem: LoginItemControl {
    var isEnabled: Bool { false }
    func set(_ enabled: Bool) -> String? {
        refuse("LoginItem.set(\(enabled))")
        return "refused by keeplight-render"
    }
}

struct FakeSystemEvents: SystemEvents {
    func observeSleepWake(willSleep: @escaping @MainActor () -> Void,
                          didWake: @escaping @MainActor () -> Void) -> [any NSObjectProtocol] {
        refuse("NSWorkspace sleep/wake observers")
        return []
    }
}

// MARK: - Shell (status item, panel, overlay windows)

/// The model's view of the shell. Every method would order a window on screen, so each refuses.
@MainActor
final class FakeShell: ShellActions {
    func openPanel() { refuse("Shell.openPanel") }
    func closePanel() { refuse("Shell.closePanel") }
    func togglePanel() { refuse("Shell.togglePanel") }
    func showRing() { refuse("Shell.showRing") }
    func dismissRing(animated: Bool) { refuse("Shell.dismissRing") }
    /// The Keep card is its own surface; the pending ticker refreshes it every second, even for
    /// panel renders that keep their model alive. Nothing is shown, so nothing is refused.
    func syncRing() {}
    func rescueHUD(_ phase: RescueHUDPhase) { refuse("Shell.rescueHUD") }
    func identify() { refuse("Shell.identify") }
    func showSettings() { refuse("Shell.showSettings") }
    func showBrightnessOSD(on id: CGDirectDisplayID, value: Double) { refuse("Shell.showBrightnessOSD") }
}

// MARK: - Services

@MainActor
enum FakeServices {
    /// `directory` is a fresh temporary folder that must stay empty.
    static func make(system: FakeDisplaySystem, directory: URL) -> AppServices {
        AppServices(directory: directory,
                    makeSystem: { _ in system },
                    persistentPreferences: false,
                    hotKeys: FakeHotKeys(),
                    loginItem: FakeLoginItem(),
                    makeBrightnessKeys: { _, _ in FakeKeyTap() },
                    systemEvents: FakeSystemEvents())
    }
}
#endif
