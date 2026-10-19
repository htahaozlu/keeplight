import AppKit
import DisplayCore
import os

/// Brightness keys for displays macOS can't dim itself (DDC monitors): the display under the
/// pointer moves one step per press and shows the instrument OSD. Built-in and Apple displays
/// keep macOS's own handling.
extension AppModel {
    /// Starts or stops the key tap to match the setting; call at launch and when the panel opens
    /// (permission may have been granted in System Settings meanwhile). Never shows the system
    /// prompt by itself: that happens only when the user turns the keys on (onboarding, Settings).
    /// Turned on but not allowed (revoked, or a rebuilt app) waits for the grant, and Settings says
    /// what is missing.
    func syncBrightnessKeys() {
        guard !flags.readOnly else { return }
        if prefs.brightnessKeys {
            brightnessKeys.verifyTrust()
            if !brightnessKeys.start() { brightnessKeys.waitForTrust() }
        } else {
            brightnessKeys.stop()
        }
        brightnessKeysActive = brightnessKeys.isRunning
    }

    func setBrightnessKeys(_ on: Bool) {
        guard !flags.readOnly else { return flashNotice("Debug mode: nothing is written.") }
        prefs.brightnessKeys = on
        if on {
            brightnessKeys.requestAndStart()
        } else {
            brightnessKeys.stop()
        }
        brightnessKeysActive = brightnessKeys.isRunning
    }

    /// External displays the brightness keys could drive (DDC control available).
    var hasKeyableDisplay: Bool {
        items.contains { brightness[$0.id]?.control?.backend == .ddc }
    }

    /// One key press. True when Keeplight used it; false lets macOS handle it.
    func handleBrightnessKey(up: Bool, fine: Bool) -> Bool {
        guard prefs.brightnessKeys, !flags.readOnly, !isSettling else { return false }
        guard let id = NSScreen.underPointer?.displayID, let item = item(id) else {
            keysLog.info("brightness key: no display under the pointer")
            return false
        }
        guard case .available(let control, let value, _) = brightness[id], control.backend == .ddc else {
            keysLog.info("brightness key: \(item.info.name, privacy: .public) has no DDC brightness (\(String(describing: self.brightness[id]?.control?.backend), privacy: .public))")
            return false
        }
        let current = value ?? prefs.lastWritten[item.fingerprint]?.value ?? 0.5
        let floor = brightnessFloor(for: id)
        let next = BrightnessPolicy.keyed(from: current, up: up, fine: fine, floor: floor)
        setBrightness(id, to: next)
        keysLog.info("brightness key: \(item.info.name, privacy: .public) \(BrightnessPolicy.percent(current))% → \(BrightnessPolicy.percent(next))%")
        // After the tap callback returns: the first OSD builds a window, and a slow tap gets disabled.
        Task { @MainActor [weak self] in self?.shell?.showBrightnessOSD(on: id, value: next) }
        return true
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private let keysLog = Logger(subsystem: "io.github.htahaozlu.Keeplight", category: "keys")

extension NSScreen {
    /// The screen under the mouse pointer.
    static var underPointer: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
