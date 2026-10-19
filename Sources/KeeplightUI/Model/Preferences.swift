import AppKit
import Foundation

/// How this launch runs.
struct LaunchFlags: Sendable {
    /// `KEEPLIGHT_DEBUG_PANEL=1`: open the panel at launch, skip onboarding, and write
    /// nothing (no display changes, no journal, no preferences on disk).
    let debug: Bool
    /// ⇧ held at launch: apply nothing except pending-change recovery [O§7.3].
    let safeStart: Bool
    /// `KEEPLIGHT_DEBUG_STATE=why=2,ring,receipt,…`: preview states for screenshots (debug only).
    let debugStates: [String: String]

    var readOnly: Bool { debug }

    static func current() -> LaunchFlags {
        let safeStart = NSEvent.modifierFlags.contains(.shift)
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        let debug = env["KEEPLIGHT_DEBUG_PANEL"] == "1"
        var states: [String: String] = [:]
        if debug {
            for part in (env["KEEPLIGHT_DEBUG_STATE"] ?? "").split(separator: ",") {
                let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                if let key = kv.first, !key.isEmpty { states[key] = kv.count > 1 ? kv[1] : "" }
            }
        }
        return LaunchFlags(debug: debug, safeStart: safeStart, debugStates: states)
        #else
        return LaunchFlags(debug: false, safeStart: safeStart, debugStates: [:])
        #endif
    }
}

/// The value Keeplight last wrote to a display's brightness (restored after wake).
struct LastWritten: Codable, Hashable, Sendable {
    var value: Double
    var date: Date
    /// On the dimmed range (`DimmingCurve`) for a DDC monitor. Nil: saved before it existed (or by
    /// Dotpitch), the monitor's own 0…1, converted at the next probe.
    var combined: Bool? = true
}

/// User settings and per-display memory in `UserDefaults` [O§4.4]. In debug mode nothing is
/// written to disk. After `eraseAll()` nothing is written again until the next launch.
@MainActor @Observable
final class Preferences {
    @ObservationIgnored private let persistentStore: UserDefaults?
    /// The defaults domain `eraseAll()` removes.
    @ObservationIgnored private let domain: String?
    @ObservationIgnored private(set) var isErased = false
    /// The store, or nil when writes are off (in-memory preferences, or erased).
    private var defaults: UserDefaults? { isErased ? nil : persistentStore }
    /// Called after F1/F2 are turned on or off (the key tap's event mask depends on it).
    @ObservationIgnored var onFunctionKeysChange: (() -> Void)?

    private enum Key {
        static let revertSeconds = "revertSeconds"
        static let restoreAfterWake = "restoreAfterWake"
        static let showInMenuBar = "showInMenuBar"
        static let onboardingVersion = "onboardingVersion"
        static let nicknames = "nicknames"
        static let knownDisplays = "knownDisplays"
        static let lastWritten = "lastWritten"
        static let brightnessKeys = "brightnessKeys"
        static let functionKeysAsBrightness = "functionKeysAsBrightness"
    }

    /// 15 or 30 seconds.
    var revertSeconds: Int { didSet { defaults?.set(revertSeconds, forKey: Key.revertSeconds) } }
    var restoreAfterWake: Bool { didSet { defaults?.set(restoreAfterWake, forKey: Key.restoreAfterWake) } }
    /// Brightness keys drive DDC displays (needs Accessibility; off until the user turns it on).
    var brightnessKeys: Bool { didSet { defaults?.set(brightnessKeys, forKey: Key.brightnessKeys) } }
    /// F1/F2 also count as brightness keys (a Magic Keyboard sends them when macOS can't dim).
    /// Off until the user turns it on: while on, plain F1/F2 over a DDC display are taken from
    /// every app (Help, Rename…).
    var functionKeysAsBrightness: Bool {
        didSet {
            defaults?.set(functionKeysAsBrightness, forKey: Key.functionKeysAsBrightness)
            if functionKeysAsBrightness != oldValue { onFunctionKeysChange?() }
        }
    }
    var showInMenuBar: Bool { didSet { defaults?.set(showInMenuBar, forKey: Key.showInMenuBar) } }
    /// The onboarding version last finished (0: never). Onboarding shows while it is below
    /// `OnboardingFlow.version`. Debug mode keeps preferences in memory, so it never writes this.
    var onboardingVersion: Int { didSet { defaults?.set(onboardingVersion, forKey: Key.onboardingVersion) } }
    /// Fingerprint → nickname.
    var nicknames: [String: String] { didSet { defaults?.set(nicknames, forKey: Key.nicknames) } }
    /// Fingerprint → name, for every display ever seen ("remembered" in Settings › Displays).
    var knownDisplays: [String: String] { didSet { defaults?.set(knownDisplays, forKey: Key.knownDisplays) } }
    /// Fingerprint → last brightness written. Saved at most 1 s after any change (also during a
    /// long drag), so a crash or force quit never leaves an older value for the wake restore.
    @ObservationIgnored var lastWritten: [String: LastWritten] { didSet { scheduleLastWrittenSave() } }
    @ObservationIgnored private var lastWrittenSave: Task<Void, Never>?

    convenience init(persistent: Bool) {
        self.init(store: persistent ? .standard : nil, domain: Bundle.main.bundleIdentifier)
    }

    init(store defaults: UserDefaults?, domain: String?) {
        persistentStore = defaults
        self.domain = domain
        let seconds = defaults?.integer(forKey: Key.revertSeconds) ?? 0
        revertSeconds = seconds == 30 ? 30 : 15
        restoreAfterWake = defaults?.object(forKey: Key.restoreAfterWake) as? Bool ?? true
        brightnessKeys = defaults?.bool(forKey: Key.brightnessKeys) ?? false
        functionKeysAsBrightness = defaults?.object(forKey: Key.functionKeysAsBrightness) as? Bool ?? false
        showInMenuBar = defaults?.object(forKey: Key.showInMenuBar) as? Bool ?? true
        onboardingVersion = defaults?.integer(forKey: Key.onboardingVersion) ?? 0
        nicknames = defaults?.dictionary(forKey: Key.nicknames) as? [String: String] ?? [:]
        knownDisplays = defaults?.dictionary(forKey: Key.knownDisplays) as? [String: String] ?? [:]
        lastWritten = (defaults?.data(forKey: Key.lastWritten))
            .flatMap { try? JSONDecoder().decode([String: LastWritten].self, from: $0) } ?? [:]
    }

    func nickname(for fingerprint: String) -> String? {
        nicknames[fingerprint].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    func setNickname(_ name: String, for fingerprint: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        nicknames[fingerprint] = trimmed.isEmpty ? nil : name
    }

    func saveLastWritten() {
        lastWrittenSave?.cancel()
        lastWrittenSave = nil
        guard let defaults, let data = try? JSONEncoder().encode(lastWritten) else { return }
        defaults.set(data, forKey: Key.lastWritten)
    }

    /// One save per second at most; changes made while one is scheduled ride along with it.
    private func scheduleLastWrittenSave() {
        guard defaults != nil, lastWrittenSave == nil else { return }
        lastWrittenSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveLastWritten()
        }
    }

    /// Erase All Keeplight Data: resets to defaults, then removes the whole defaults domain
    /// (in that order, so the resets don't write the keys back) and stops writing for good.
    func eraseAll() {
        // The resets must not rebuild the key tap one by one; the callback comes back afterwards.
        let functionKeysCallback = onFunctionKeysChange
        onFunctionKeysChange = nil
        defer { onFunctionKeysChange = functionKeysCallback }
        revertSeconds = 15
        restoreAfterWake = true
        brightnessKeys = false
        functionKeysAsBrightness = false
        showInMenuBar = true
        onboardingVersion = 0
        nicknames = [:]
        knownDisplays = [:]
        lastWritten = [:]
        lastWrittenSave?.cancel()
        lastWrittenSave = nil
        if let persistentStore, let domain { persistentStore.removePersistentDomain(forName: domain) }
        isErased = true
    }
}
