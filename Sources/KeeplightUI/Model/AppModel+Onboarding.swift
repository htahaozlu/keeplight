import Foundation

/// Onboarding pages (docs/design/v4-keeplight.md §4): what Keeplight is, how a risky change waits
/// for Keep, and — only with a display the brightness keys could drive — the keys with their one
/// Accessibility request.
enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, keep, keys
}

/// The brightness-keys permission on page 3.
enum KeysPermission: Equatable, Sendable {
    /// `Allow…` not pressed yet.
    case notAsked
    /// Keys on, the system prompt shown once, waiting for the grant.
    case waiting
    /// Trusted: the key tap runs.
    case granted
    /// `Not Now`, Esc or closing: keys off, nothing nags (Settings carries the row).
    case deferred
}

/// The onboarding window's state, apart from its views: the page, the permission state machine
/// and the `Open at login` choice. Shown while `Preferences.onboardingVersion < version`.
@MainActor @Observable
final class OnboardingFlow {
    /// Bumped when onboarding changes enough to be shown again.
    static let version = 1

    @ObservationIgnored let model: AppModel
    /// Settable for previews and tests; the app moves it only through the methods below.
    var permission: KeysPermission
    /// The last page's switch: on by default, applied by `Done` / `Not Now`.
    var openAtLogin = true
    private(set) var isFinished = false

    init(model: AppModel) {
        self.model = model
        permission = model.prefs.brightnessKeys && model.brightnessKeysActive ? .granted : .notAsked
        model.onboardingStep = .welcome
    }

    var step: OnboardingStep {
        get { model.onboardingStep }
        set { model.onboardingStep = newValue }
    }

    /// The pages for this desk: `keys` only when a monitor the keys could drive is connected (or
    /// the page is already up).
    var steps: [OnboardingStep] {
        model.hasKeyableDisplay || step == .keys ? OnboardingStep.allCases : [.welcome, .keep]
    }

    var index: Int { steps.firstIndex(of: step) ?? 0 }
    var isLast: Bool { steps.last == step }

    /// `Continue`; on the last page `Done`, which finishes.
    func advance() {
        let steps = steps
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return finish(applyLogin: true) }
        step = steps[i + 1]
    }

    /// `Back` (⌘[).
    func back() {
        let steps = steps
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        step = steps[i - 1]
    }

    /// `Allow…`: the keys on, the system prompt once; granted at once if already trusted.
    func allow() {
        guard permission == .notAsked || permission == .deferred else { return }
        if !model.flags.readOnly { model.setBrightnessKeys(true) }
        permission = model.brightnessKeysActive ? .granted : .waiting
    }

    /// `Not Now` (and Esc on page 3): the keys stay off, onboarding ends.
    func notNow() {
        deferKeys()
        finish(applyLogin: true)
    }

    /// Re-reads the tap after an event (Accessibility broadcast, app active, the 1 Hz fallback).
    /// True when access was granted just now.
    @discardableResult
    func syncPermission() -> Bool {
        guard permission == .waiting, model.prefs.brightnessKeys, model.brightnessKeysActive else { return false }
        permission = .granted
        return true
    }

    /// The 1 Hz fallback's look: starts the tap if Accessibility was granted meanwhile.
    @discardableResult
    func checkTrust() -> Bool {
        guard permission == .waiting else { return false }
        model.brightnessKeys.verifyTrust()
        model.brightnessKeysActive = model.brightnessKeys.isRunning
        return syncPermission()
    }

    /// The fallback timer runs only while page 3 waits and is on screen (covered still counts).
    func wantsTrustPolling(onScreen: Bool) -> Bool {
        !isFinished && onScreen && step == .keys && permission == .waiting
    }

    /// Done, Not Now, Esc or closing the window. A permission still waiting is deferred (keys off).
    /// `applyLogin`: the last page's switch was answered (its button), so the login item follows it.
    func finish(applyLogin: Bool) {
        guard !isFinished else { return }
        isFinished = true
        if permission == .waiting { deferKeys() }
        if applyLogin, isLast, !model.flags.readOnly, openAtLogin != model.launchAtLogin {
            model.setLaunchAtLogin(openAtLogin)
        }
        model.finishFirstRun()
    }

    private func deferKeys() {
        if model.prefs.brightnessKeys, permission != .granted, !model.flags.readOnly { model.setBrightnessKeys(false) }
        if permission != .granted { permission = .deferred }
    }

    /// Names of the monitors the keys would drive.
    var keyableDisplayNames: [String] { model.keyableDisplayNames }
}

extension AppModel {
    /// Names of the monitors the keys would drive.
    var keyableDisplayNames: [String] {
        items.filter { brightness[$0.id]?.control?.backend == .ddc }.map { name($0.info) }
    }
}
