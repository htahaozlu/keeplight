import AppKit
import DisplayCore

/// The display system as the app uses it: DisplayCore's `DisplaySystem` (inventory, snapshot,
/// rescue steps) plus the panel's other configuration, probing and observation calls.
/// `LiveDisplaySystem` in the app.
protocol AppDisplaySystem: DisplaySystem {
    func mirror(_ target: CGDirectDisplayID, of source: CGDirectDisplayID, option: CGConfigureOption) throws
    func execute(_ plan: [RestoreAction], option: CGConfigureOption) -> [RestoreStep]
    /// The best brightness backend. May block for a DDC probe; call off the main thread.
    func brightnessControl(for display: DisplayInfo) -> (any BrightnessControl)?
    /// The graded diagnosis. May block for a DDC probe; call off the main thread.
    func diagnose(_ display: DisplayInfo) -> DiagnosticReport
    func edid(for display: DisplayInfo) -> EDID?
    /// Calls `handler` after each display reconfiguration while the returned token is alive.
    func observeReconfiguration(_ handler: @escaping @Sendable () -> Void) -> AnyObject
}

extension LiveDisplaySystem: AppDisplaySystem {
    func mirror(_ target: CGDirectDisplayID, of source: CGDirectDisplayID, option: CGConfigureOption) throws {
        try DisplayManager.mirror(target, of: source, option: option)
    }

    func execute(_ plan: [RestoreAction], option: CGConfigureOption) -> [RestoreStep] {
        DisplayManager.execute(plan, option: option)
    }

    /// DDC monitors get the dimmed range below their own minimum (`DimmingBrightness`).
    func brightnessControl(for display: DisplayInfo) -> (any BrightnessControl)? {
        guard let control = Brightness.control(for: display) else { return nil }
        return control.backend == .ddc ? DimmingBrightness(base: control, dimmer: liveDimmer) : control
    }
    func diagnose(_ display: DisplayInfo) -> DiagnosticReport { Diagnostics.diagnose(display) }
    func edid(for display: DisplayInfo) -> EDID? { EDID.read(for: display) }

    func observeReconfiguration(_ handler: @escaping @Sendable () -> Void) -> AnyObject {
        DisplayManager.observeReconfiguration(handler)
    }
}

/// Global shortcuts (`HotKeys`).
@MainActor
protocol HotKeyRegistry: AnyObject {
    /// False when macOS refused (e.g. another app holds the chord).
    @discardableResult
    func register(_ key: HotKeys.Key, onPress: @escaping @MainActor () -> Void,
                  onRelease: (@MainActor () -> Void)?) -> Bool
    func unregister(_ key: HotKeys.Key)
}

extension HotKeys: HotKeyRegistry {}

/// The brightness-key event tap and its Accessibility grant (`BrightnessKeys`).
@MainActor
protocol BrightnessKeyTap: AnyObject {
    var isRunning: Bool { get }
    var onChange: (@MainActor () -> Void)? { get set }
    @discardableResult func start() -> Bool
    func requestAndStart()
    func waitForTrust()
    func stop()
    /// F1/F2 were turned on or off: the tap's event mask follows.
    func functionKeysChanged()
    /// Looks at Accessibility now: starts the tap once granted, drops it once revoked.
    func verifyTrust()
}

extension BrightnessKeyTap {
    func functionKeysChanged() {}
    func verifyTrust() {}
}

extension BrightnessKeys: BrightnessKeyTap {}

/// Open at login (`SMAppService`).
@MainActor
protocol LoginItemControl {
    var isEnabled: Bool { get }
    /// Returns an error message, or nil on success.
    func set(_ enabled: Bool) -> String?
}

struct LiveLoginItem: LoginItemControl {
    var isEnabled: Bool { LoginItem.isEnabled }
    func set(_ enabled: Bool) -> String? { LoginItem.set(enabled) }
}

/// Sleep and wake (`NSWorkspace` notifications). Returns the observers to keep alive.
@MainActor
protocol SystemEvents {
    func observeSleepWake(willSleep: @escaping @MainActor () -> Void,
                          didWake: @escaping @MainActor () -> Void) -> [any NSObjectProtocol]
}

struct LiveSystemEvents: SystemEvents {
    /// Sleep is delivered on the main thread, so a pending change reverts with no queue hop.
    func observeSleepWake(willSleep: @escaping @MainActor () -> Void,
                          didWake: @escaping @MainActor () -> Void) -> [any NSObjectProtocol] {
        let center = NSWorkspace.shared.notificationCenter
        var observers = [center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { willSleep() }
        }]
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { didWake() }
            })
        }
        return observers
    }
}

/// Everything system-facing the model and the shell use, so each piece can be swapped.
@MainActor
struct AppServices {
    /// Journal, registries, known-good setups and `pending.json`.
    var directory: URL
    /// Display inventory and configuration over `registry`; also the transaction engine's applier.
    var makeSystem: (_ registry: DisconnectedRegistry) -> any AppDisplaySystem
    /// Preferences in `UserDefaults.standard`; false keeps them in memory.
    var persistentPreferences: Bool
    var hotKeys: any HotKeyRegistry
    var loginItem: any LoginItemControl
    var makeBrightnessKeys: (_ useFunctionKeys: @escaping @MainActor () -> Bool,
                             _ handler: @escaping BrightnessKeys.Handler) -> any BrightnessKeyTap
    var systemEvents: any SystemEvents
    /// Gamma dimming below a monitor's minimum. Fakes get one that never touches a real table.
    var dimmer = SoftwareDimmer(tables: NoGammaTables())

    static var live: AppServices {
        AppServices(directory: Keeplight.supportDirectory,
                    makeSystem: { LiveDisplaySystem(registry: $0) },
                    persistentPreferences: true,
                    hotKeys: HotKeys.shared,
                    loginItem: LiveLoginItem(),
                    makeBrightnessKeys: { BrightnessKeys(useFunctionKeys: $0, handler: $1) },
                    systemEvents: LiveSystemEvents(),
                    dimmer: liveDimmer)
    }
}

/// The one dimmer of the running app: the live display system's DDC controls write to it.
let liveDimmer = SoftwareDimmer()

/// Gamma tables that do nothing (tests, the render tool).
struct NoGammaTables: GammaTables {
    func read(_ id: CGDirectDisplayID) -> GammaTable? { nil }
    func write(_ table: GammaTable, to id: CGDirectDisplayID) -> Bool { false }
}
