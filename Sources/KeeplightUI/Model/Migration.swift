import DisplayCore
import Foundation

/// Preferences that survive the rename (docs/design/v4-keeplight.md §7). Dotpitch kept its
/// preferences in the `io.github.htahaozlu.Dotpitch` defaults domain; Keeplight's bundle id gives a
/// new, empty domain. Once, before anything reads the preferences, the per-display memory and two
/// safety settings are copied over — only keys the new domain does not have yet. Never
/// `hasLaunched` (the renamed app shows onboarding), `brightnessKeys` or the F1/F2 setting (the
/// Accessibility grant belonged to the old app's identity).
enum DefaultsMigration {
    static let legacyDomain = LegacyData.bundleIdentifier

    /// The keys imported, each with the type Keeplight's `Preferences` reads.
    static let keys = ["nicknames", "knownDisplays", "lastWritten", "revertSeconds", "restoreAfterWake"]

    /// Copies the imported keys of `legacy` (a domain's contents) into `target` where `target` has
    /// none, skipping values of the wrong type. Returns the keys written, sorted.
    @discardableResult
    static func importLegacy(_ legacy: [String: Any]?, into target: UserDefaults) -> [String] {
        guard let legacy else { return [] }
        var written: [String] = []
        for key in keys {
            guard target.object(forKey: key) == nil, let value = legacy[key], isValid(value, for: key) else { continue }
            target.set(value, forKey: key)
            written.append(key)
        }
        return written.sorted()
    }

    /// Set in the old domain once the import ran, so it runs once: after Erase All Keeplight Data
    /// the old values must not come back. Dotpitch never reads it.
    static let importedMarker = "importedIntoKeeplight"

    /// The live run: the old domain from the user's defaults into `UserDefaults.standard`, once.
    @discardableResult
    static func run(defaults: UserDefaults = .standard, legacyDomain: String = legacyDomain) -> [String] {
        guard let legacy = defaults.persistentDomain(forName: legacyDomain), legacy[importedMarker] == nil else { return [] }
        let written = importLegacy(legacy, into: defaults)
        // One key, not a rewrite of the domain: Dotpitch may be running and writing its own keys.
        UserDefaults(suiteName: legacyDomain)?.set(true, forKey: importedMarker)
        return written
    }

    private static func isValid(_ value: Any, for key: String) -> Bool {
        switch key {
        case "nicknames", "knownDisplays":
            return value is [String: String]
        case "lastWritten":
            guard let data = value as? Data else { return false }
            return (try? JSONDecoder().decode([String: LastWritten].self, from: data)) != nil
        case "revertSeconds":
            guard let seconds = value as? Int else { return false }
            return seconds == 15 || seconds == 30
        case "restoreAfterWake":
            // A plist bool reads back as NSNumber; only 0/1 make sense.
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        default:
            return false
        }
    }
}
