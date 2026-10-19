import DisplayCore
import Foundation
import Security
import ServiceManagement

/// Version, architecture, commit and code signature for Settings › About.
enum BuildInfo {
    /// `0.3.0`: DisplayCore's version, which the app and the CLI share.
    static var shortVersion: String { Keeplight.version }

    /// `0.3.0 (3)`: with the bundle's build number when there is one (the report).
    static var version: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(shortVersion) (\($0))" } ?? shortVersion
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// `0.3.0 · arm64`, the About header.
    static var versionLine: String { "\(shortVersion) · \(architecture)" }

    /// `DPGitCommit`, baked into Info.plist by `scripts/bundle-app.sh`.
    static var commit: String {
        Bundle.main.infoDictionary?["DPGitCommit"] as? String ?? "unknown"
    }

    /// "Developer ID · TEAMID", "Ad-hoc — built from source", or "Unsigned".
    static var signature: String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "Unsigned" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "Unsigned" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess, let dict = info as? [String: Any] else { return "Unsigned" }
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return "Developer ID · \(team)"
        }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return "Ad-hoc — built from source" }
        return dict[kSecCodeInfoIdentifier as String] == nil ? "Unsigned" : "Signed"
    }
}

/// Open at login through `SMAppService` (appears in System Settings › General › Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil on success.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Open at login: \(error.localizedDescription)"
        }
    }
}
