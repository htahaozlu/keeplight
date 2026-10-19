import Foundation

/// Every word of the onboarding window (docs/design/v4-keeplight.md §4), exact.
enum OnboardingCopy {
    static let wordmark = "Keeplight"
    static let welcomeLine = "Brightness and resolution for every display."

    static let keepTitle = "Changes wait for Keep"
    static let keepLine = "Unless you press Keep, changes go back."
    static let rescueLine = "Screen gone? Hold ⌃⌥⌘R."

    static let keysTitle = "Brightness keys"
    static let askOnce = "macOS asks once for Accessibility permission."
    static let waiting = "Waiting for permission…"
    static let notWorking = "Not working?"
    static let fix = "Remove Keeplight with −, then add it again."
    static let keysOn = "Brightness keys are on."

    /// "Use your keyboard's brightness keys on BenQ EW3270U." with one monitor the keys drive,
    /// "on your external displays" with more (or none known yet).
    static func keysLine(names: [String]) -> String {
        "Use your keyboard's brightness keys on \(names.count == 1 ? names[0] : "your external displays")."
    }

    static let openAtLogin = "Open at login"

    static let continueLabel = "Continue"
    static let back = "Back"
    static let done = "Done"
    static let notNow = "Not Now"
    static let allow = "Allow…"
    static let openSystemSettings = "Open System Settings…"

    // Words drawn inside the scenes.
    static let sceneKeep = "Keep"
    static let sceneRevert = "Revert"
    static let sceneReverted = "Reverted"
    static let sceneKeepTitle = "Keep 3008 × 1692?"
    static let scenePane = "Privacy & Security › Accessibility"

    // VoiceOver only.
    static func step(_ index: Int, of count: Int) -> String { "Step \(index + 1) of \(count)" }  // copy-budget: spoken
    static let replayHelp = "Click to replay."  // copy-budget: spoken
    static let replay = "Replay"  // copy-budget: spoken
    static let lightLabel = "Your displays light up."  // copy-budget: spoken
    static let fuseLabel = "A Keep card counts down, then the change goes back."  // copy-budget: spoken
    static let keysLabel = "A brightness key press shows the brightness level."  // copy-budget: spoken
    static let accessLabel = "Keeplight is turned on in Privacy & Security, Accessibility."  // copy-budget: spoken
}
