import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "io.github.htahaozlu.Keeplight", category: "keys")

/// Reads the keyboard's brightness keys with a session event tap (needs Accessibility) and asks
/// `handler` what to do with each press: true consumes it (Keeplight adjusted a DDC display),
/// false passes it on so macOS handles built-in and Apple displays with its own OSD.
/// The sun keys reach the session in one of three forms (`BrightnessKeyCode`), depending on the
/// keyboard and on whether macOS has a screen it can dim: `NX_SYSDEFINED` brightness events, the
/// key codes 144/145 (an Apple keyboard with no dimmable screen, e.g. a MacBook in clamshell), or
/// F15/F14 (desktop Macs). F1/F2 count too when the user turned that on. Every other event passes
/// untouched and unread.
@MainActor
final class BrightnessKeys {
    /// `(up, fine)` → consumed. `fine` is ⌥⇧ held (quarter steps).
    typealias Handler = @MainActor (_ up: Bool, _ fine: Bool) -> Bool

    private static let systemDefined = 14          // NX_SYSDEFINED
    private static let auxControlButtons: Int16 = 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private static let brightnessUp = 2             // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown = 3           // NX_KEYTYPE_BRIGHTNESS_DOWN
    /// The forms already logged once (`keys: arriving as …`), for support without logging keys.
    private var loggedForms: Set<String> = []

    private let handler: Handler
    /// Whether F1/F2 count as brightness keys (Settings › General).
    private let useFunctionKeys: @MainActor () -> Bool
    private var consumedFunctionKeys: Set<Int64> = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys whose key-down we consumed; their key-up is consumed too.
    private var consumedDown: Set<Int> = []
    private var trustObserver: (any NSObjectProtocol)?
    private var activeObserver: (any NSObjectProtocol)?
    /// Called when the tap starts or stops.
    var onChange: (@MainActor () -> Void)?

    init(useFunctionKeys: @escaping @MainActor () -> Bool, handler: @escaping Handler) {
        self.useFunctionKeys = useFunctionKeys
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The events the tap listens to: system-defined events and key down/up, because two of the
    /// three forms of the sun keys are key codes. Key events other than `BrightnessKeyCode`'s are
    /// passed on at once without being read further.
    static let eventMask: CGEventMask = (CGEventMask(1) << CGEventMask(systemDefined))
        | (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
        | (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue))

    enum TrustAction: Equatable { case start, stop, none }

    /// What a look at Accessibility means for the tap: install it once granted, drop it once
    /// revoked. Once the user turned the keys off (`following` false) a late look does nothing.
    static func trustAction(running: Bool, trusted: Bool, following: Bool = true) -> TrustAction {
        guard following || running else { return .none }
        return switch (running, trusted) {
        case (false, true): .start
        case (true, false): .stop
        default: .none
        }
    }

    /// Shows the system Accessibility prompt (once per app identity), then waits for the grant.
    func requestAndStart() {
        // The value of `kAXTrustedCheckOptionPrompt` (a mutable global, so not usable under Swift 6).
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        // Granted but the tap could not be made: keep watching instead of giving up.
        if AXIsProcessTrustedWithOptions(prompt), start() { return }
        waitForTrust()
    }

    /// Follows the Accessibility grant for as long as the setting is on: starts the tap when it
    /// is granted, however long that takes, and drops it when it is revoked. Event-driven, no
    /// timer: the system's accessibility-change notification (TCC writes its database just after
    /// posting, so look again at 0.5 s and 1.5 s) and the app becoming active again (the user
    /// returning from System Settings).
    func waitForTrust() {
        guard trustObserver == nil else { return }
        log.info("brightness keys: watching Accessibility")
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.recheck(after: [.milliseconds(500), .milliseconds(1500)]) }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.verifyTrust() }
        }
    }

    private func recheck(after delays: [Duration]) async {
        for delay in delays {
            try? await Task.sleep(for: delay)
            verifyTrust()
        }
    }

    /// Looks at Accessibility now and starts or drops the tap to match. A re-check that was still
    /// scheduled when the keys were turned off finds nothing to follow and does nothing.
    func verifyTrust() {
        switch Self.trustAction(running: tap != nil, trusted: Self.isTrusted, following: trustObserver != nil) {
        case .start:
            start()
        case .stop:
            log.info("brightness keys: Accessibility revoked, tap removed")
            removeTap()
            onChange?()
        case .none:
            break
        }
    }

    /// The F1/F2 setting changed. The tap's mask already has key events; `useFunctionKeys` is read
    /// per press, so nothing needs rebuilding.
    func functionKeysChanged() {}

    /// Installs the tap if Accessibility is granted. Returns whether it is running.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.isTrusted else {
            log.info("brightness keys: Accessibility not granted, tap not installed")
            return false
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: Self.eventMask,
                                          callback: brightnessKeyCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log.error("brightness keys: CGEvent.tapCreate failed although Accessibility is granted")
            return false
        }
        log.info("brightness keys: tap installed")
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        // Keep following Accessibility so a later revoke removes the tap.
        waitForTrust()
        onChange?()
        return true
    }

    private func stopWaiting() {
        if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
        trustObserver = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    func stop() {
        stopWaiting()
        let wasRunning = tap != nil
        removeTap()
        if wasRunning { onChange?() }
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        consumedDown = []
        consumedFunctionKeys = []
    }

    /// macOS disables a tap that is too slow, when secure input starts, or when Accessibility is
    /// revoked; turn it back on unless it is no longer allowed.
    fileprivate func reenable() {
        guard Self.isTrusted else { return verifyTrust() }
        log.info("brightness keys: tap re-enabled after macOS disabled it")
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// True to swallow `event`.
    fileprivate func handle(_ event: CGEvent) -> Bool {
        if event.type == .keyDown || event.type == .keyUp { return handleKeyCode(event) }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
              ns.subtype.rawValue == Self.auxControlButtons else { return false }
        let data = ns.data1
        let key = (data & 0xFFFF_0000) >> 16
        guard key == Self.brightnessUp || key == Self.brightnessDown else { return false }
        noteForm("system-defined brightness event")
        switch (data & 0xFF00) >> 8 {
        case 0xA:  // key down (also auto-repeat)
            // ⌃ + sun and ⌘ + sun are macOS shortcuts; bare, ⌥ or ⌥⇧ is ours (fine steps with ⌥).
            // A press Keeplight does not handle (an Apple display) still reaches macOS, so ⌥ + sun
            // there opens Displays settings as before.
            guard Self.isOurs(event.flags) else { consumedDown.remove(key); return false }
            let consumed = handler(key == Self.brightnessUp, Self.isFine(event.flags))
            if consumed { consumedDown.insert(key) } else { consumedDown.remove(key) }
            return consumed
        case 0xB:  // key up
            return consumedDown.remove(key) != nil
        default:
            return false
        }
    }

    /// No modifier, ⌥, or ⌥⇧ (the last two: fine steps). ⌘, ⌃ or ⇧ alone stay shortcuts.
    static func isOurs(_ flags: CGEventFlags) -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let held = flags.intersection(modifiers)
        return held.isEmpty || held == .maskAlternate || held == [.maskAlternate, .maskShift]
    }

    /// 144/145, F15/F14, and F1/F2 when they count; with no modifier (or ⌥⇧ for fine steps).
    /// ⌘F1, ⌃F2… stay shortcuts. A key-up is swallowed only when its key-down was.
    private func handleKeyCode(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if event.type == .keyUp { return consumedFunctionKeys.remove(code) != nil }
        guard let up = BrightnessKeyCode.direction(of: code, functionKeys: useFunctionKeys()) else { return false }
        noteForm("key code \(code)")
        guard Self.isOurs(event.flags) else { return false }
        let consumed = handler(up, Self.isFine(event.flags))
        if consumed { consumedFunctionKeys.insert(code) } else { consumedFunctionKeys.remove(code) }
        return consumed
    }

    /// Once per form and launch: which form this Mac's sun keys arrive in.
    private func noteForm(_ form: String) {
        guard loggedForms.insert(form).inserted else { return }
        log.info("brightness keys: arriving as \(form, privacy: .public)")
    }

    /// ⌥ held (with or without ⇧, macOS's own fine-step chord): quarter steps.
    static func isFine(_ flags: CGEventFlags) -> Bool { flags.contains(.maskAlternate) }
}

private func brightnessKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<BrightnessKeys>.fromOpaque(refcon).takeUnretainedValue()
    // The run-loop source is on the main run loop.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { keys.reenable() }
        return Unmanaged.passUnretained(event)
    }
    // Called on the main thread; the event is only read there, synchronously.
    nonisolated(unsafe) let mainEvent = event
    let consumed = MainActor.assumeIsolated { keys.handle(mainEvent) }
    return consumed ? nil : Unmanaged.passUnretained(event)
}

/// The key codes the sun keys arrive as when they are not system-defined events.
enum BrightnessKeyCode {
    /// Apple keyboard sun keys when macOS has no screen it can dim (clamshell, Mac mini).
    static let appleUp: Int64 = 144
    static let appleDown: Int64 = 145
    /// Desktop Macs: F15 brightens, F14 dims.
    static let f15: Int64 = 113
    static let f14: Int64 = 107
    static let f2: Int64 = 120
    static let f1: Int64 = 122

    /// True for up, false for down, nil for any other key (F1/F2 only when `functionKeys`).
    static func direction(of code: Int64, functionKeys: Bool) -> Bool? {
        switch code {
        case appleUp, f15: true
        case appleDown, f14: false
        case f2 where functionKeys: true
        case f1 where functionKeys: false
        default: nil
        }
    }
}
