import AppKit
import DisplayCore
import Foundation
@testable import KeeplightUI

// An `AppModel` on in-memory fakes: nothing here touches CoreGraphics, IOKit, the real
// preferences or the real support directory.

/// A control that records writes and can be told to fail.
final class RecordingControl: BrightnessControl, @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let backend: BrightnessBackend
    private let lock = NSLock()
    private var level: Double
    private var written: [Double] = []
    private var failing = false

    init(displayID: CGDirectDisplayID, backend: BrightnessBackend, level: Double) {
        self.displayID = displayID
        self.backend = backend
        self.level = level
    }

    var writes: [Double] { lock.withLock { written } }
    var shouldFail: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func brightness() throws -> Double { lock.withLock { level } }

    func setBrightness(_ value: Double) throws {
        try lock.withLock {
            if failing { throw DisplayError.ddc("raw DDC failure 0x6e") }
            written.append(value)
            level = value
        }
    }
}

/// One mutable desk. `failRestore` makes every restore step fail.
final class FakeDesk: AppDisplaySystem, @unchecked Sendable {
    private let lock = NSLock()
    var infos: [DisplayInfo]
    var modesByID: [CGDirectDisplayID: [DisplayMode]]
    var controls: [CGDirectDisplayID: RecordingControl] = [:]
    private var restoreFails = false
    private var modeCalls: [Int32] = []

    init(infos: [DisplayInfo], modes: [CGDirectDisplayID: [DisplayMode]]) {
        self.infos = infos
        modesByID = modes
    }

    var failRestore: Bool {
        get { lock.withLock { restoreFails } }
        set { lock.withLock { restoreFails = newValue } }
    }

    var setModeCalls: [Int32] { lock.withLock { modeCalls } }

    func snapshot() -> DisplaySnapshot {
        DisplaySnapshot(displays: infos.map { d in
            DisplaySnapshot.Entry(fingerprint: d.fingerprint, displayID: d.id, name: d.name,
                                  modeNumber: d.currentMode?.modeNumber, modeLabel: d.currentMode?.label,
                                  origin: DisplayOrigin(d.bounds.origin), isMain: d.isMain, isBuiltin: d.isBuiltin)
        }, takenAt: Date(timeIntervalSince1970: 0))
    }

    func restore(_ snapshot: DisplaySnapshot, option: CGConfigureOption) -> [RestoreStep] {
        let plan = DisplaySnapshot.restorePlan(from: self.snapshot(), to: snapshot)
        if failRestore { return plan.map { RestoreStep(action: $0, error: "CGError 1001") } }
        for target in snapshot.displays {
            guard let number = target.modeNumber else { continue }
            try? setMode(number, for: target.displayID, option: option)
        }
        return plan.map { RestoreStep(action: $0) }
    }

    func displays() -> [DisplayInfo] { infos }
    func modes(for id: CGDirectDisplayID) -> [DisplayMode] { modesByID[id] ?? [] }
    func nativePixelSize(for id: CGDirectDisplayID) -> (width: Int, height: Int)? { (2560, 1440) }
    func isPhysical(_ id: CGDirectDisplayID) -> Bool { true }
    func setEnabled(_ enabled: Bool, for id: CGDirectDisplayID, option: CGConfigureOption) throws {}
    func setMain(_ id: CGDirectDisplayID, option: CGConfigureOption) throws {}

    func setMode(_ modeNumber: Int32, for id: CGDirectDisplayID, option: CGConfigureOption) throws {
        lock.withLock { modeCalls.append(modeNumber) }
        guard let i = infos.firstIndex(where: { $0.id == id }),
              let mode = modesByID[id]?.first(where: { $0.modeNumber == modeNumber }) else { return }
        infos[i].currentMode = mode
    }

    func unmirror(_ id: CGDirectDisplayID, option: CGConfigureOption) throws {}
    func mirror(_ target: CGDirectDisplayID, of source: CGDirectDisplayID, option: CGConfigureOption) throws {}
    func execute(_ plan: [RestoreAction], option: CGConfigureOption) -> [RestoreStep] { plan.map { RestoreStep(action: $0) } }

    /// When set, DDC controls come wrapped like the live system's (`DimmingBrightness`).
    var dimmer: SoftwareDimmer?

    func brightnessControl(for display: DisplayInfo) -> (any BrightnessControl)? {
        guard let control = controls[display.id] else { return nil }
        if let dimmer, control.backend == .ddc { return DimmingBrightness(base: control, dimmer: dimmer) }
        return control
    }
    func diagnose(_ display: DisplayInfo) -> DiagnosticReport { Self.report(for: display) }
    func edid(for display: DisplayInfo) -> EDID? { nil }
    func observeReconfiguration(_ handler: @escaping @Sendable () -> Void) -> AnyObject { NSObject() }

    private struct Wire: Encodable {
        var display: String
        var fingerprint: String
        var steps: [DiagnosticStep] = []
        var verdict: String
        var facts: DiagnosticFacts
        var hardwareModel = "Mac15,6"
        var architecture = "arm64"
        var macOS = "26.5"
        var edid: String?
        var serial: String?
        var keeplightVersion = "test"
        var generatedAt = Date(timeIntervalSinceReferenceDate: 0)
    }

    private static func report(for info: DisplayInfo) -> DiagnosticReport {
        let facts = DiagnosticFacts(connection: .virtual, isIntel: false, hardwareModel: "Mac15,6",
                                    appleBrightness: false, ddcChannel: nil, ddcReply: .notTested)
        let wire = Wire(display: info.name, fingerprint: info.fingerprint, verdict: Diagnostics.verdict(for: facts),
                        facts: facts)
        // The wire type encodes exactly what `DiagnosticReport` decodes.
        guard let data = try? JSONEncoder().encode(wire),
              let report = try? JSONDecoder().decode(DiagnosticReport.self, from: data) else {
            preconditionFailure("test report did not round-trip")
        }
        return report
    }
}

@MainActor
final class RecordingShell: ShellActions {
    var rings = 0
    var dismissals: [Bool] = []
    var huds: [RescueHUDPhase] = []

    func openPanel() {}
    func closePanel() {}
    func togglePanel() {}
    func showRing() { rings += 1 }
    func dismissRing(animated: Bool) { dismissals.append(animated) }
    func identify() {}
    func showSettings() {}
    func showBrightnessOSD(on id: CGDirectDisplayID, value: Double) {}
    func syncRing() {}
    func rescueHUD(_ phase: RescueHUDPhase) { huds.append(phase) }
}

@MainActor
final class RecordingKeyTap: BrightnessKeyTap {
    var isRunning = false
    var onChange: (@MainActor () -> Void)?
    var functionKeyChanges = 0
    var stops = 0
    /// System prompts shown (`requestAndStart`) and quiet waits for the grant.
    var requests = 0
    var waits = 0
    /// Looks at Accessibility (`verifyTrust`, the onboarding's 1 Hz fallback among others).
    var verifies = 0
    /// What Accessibility says: once true, the next request or look starts the tap.
    var trusted = false

    func start() -> Bool {
        guard trusted else { return false }
        run()
        return true
    }
    func requestAndStart() {
        requests += 1
        if trusted { run() }
    }
    func waitForTrust() { waits += 1 }
    func stop() { stops += 1; isRunning = false }
    func functionKeysChanged() { functionKeyChanges += 1 }
    func verifyTrust() {
        verifies += 1
        if trusted { run() }
    }

    private func run() {
        guard !isRunning else { return }
        isRunning = true
        onChange?()
    }
}

/// Open at login that records what it was asked.
@MainActor
final class RecordingLoginItem: LoginItemControl {
    private(set) var calls: [Bool] = []
    private var enabled = false
    var isEnabled: Bool { enabled }
    func set(_ enabled: Bool) -> String? {
        calls.append(enabled)
        self.enabled = enabled
        return nil
    }
}

@MainActor
final class QuietHotKeys: HotKeyRegistry {
    func register(_ key: HotKeys.Key, onPress: @escaping @MainActor () -> Void,
                  onRelease: (@MainActor () -> Void)?) -> Bool { true }
    func unregister(_ key: HotKeys.Key) {}
}

struct QuietLoginItem: LoginItemControl {
    var isEnabled: Bool { false }
    func set(_ enabled: Bool) -> String? { nil }
}

struct QuietSystemEvents: SystemEvents {
    func observeSleepWake(willSleep: @escaping @MainActor () -> Void,
                          didWake: @escaping @MainActor () -> Void) -> [any NSObjectProtocol] { [] }
}

/// A model, its fakes and its temporary support directory.
@MainActor
final class Rig {
    let directory: URL
    let desk: FakeDesk
    let model: AppModel
    let shell = RecordingShell()
    let keys: RecordingKeyTap
    let login: RecordingLoginItem

    /// Mode 1: 2560 × 1440 @ 60 (the default), mode 2: 3008 × 1692 @ 60, mode 3: 2560 × 1440 @ 120.
    static let modes = [
        DisplayMode(modeNumber: 1, width: 2560, height: 1440, refreshRate: 60, depth: 8, density: 1, flags: 0x5),
        DisplayMode(modeNumber: 2, width: 3008, height: 1692, refreshRate: 60, depth: 8, density: 1, flags: 0x1),
        DisplayMode(modeNumber: 3, width: 2560, height: 1440, refreshRate: 120, depth: 8, density: 1, flags: 0x1),
    ]

    /// `brightness`: display 7 has this backend at this level before the first inventory, so the
    /// probe finds it.
    init(builtin: Bool = false, startMode: Int32 = 1, brightness: (BrightnessBackend, Double)? = nil, debug: Bool = false) {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeplight-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = DisplayInfo(id: 7, name: "Test Display", vendorID: 1, productID: 2, serialNumber: 3, uuid: nil,
                               isBuiltin: builtin, isMain: true, isActive: true, isOnline: true, mirrorSource: nil,
                               bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), rotation: 0,
                               currentMode: Self.modes.first { $0.modeNumber == startMode }, fingerprint: "TEST:1")
        desk = FakeDesk(infos: [info], modes: [7: Self.modes])
        if let (backend, level) = brightness {
            desk.controls[7] = RecordingControl(displayID: 7, backend: backend, level: level)
        }
        let desk = desk
        let tap = RecordingKeyTap()
        keys = tap
        let login = RecordingLoginItem()
        self.login = login
        let services = AppServices(directory: directory, makeSystem: { _ in desk }, persistentPreferences: false,
                                   hotKeys: QuietHotKeys(), loginItem: login,
                                   makeBrightnessKeys: { _, _ in tap }, systemEvents: QuietSystemEvents())
        let engine = TransactionEngine(applier: desk, directory: directory, source: .panel)
        model = AppModel(flags: LaunchFlags(debug: debug, safeStart: false, debugStates: [:]), engine: engine,
                         recovered: nil, services: services)
        model.shell = shell
        model.refresh()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var control: RecordingControl? { desk.controls[7] }

    /// True once the probe has found display 7's brightness control.
    var hasBrightness: Bool {
        if case .available = model.brightness[7] { return true }
        return false
    }

    /// Waits for a condition the model reaches through its background queues.
    func eventually(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
