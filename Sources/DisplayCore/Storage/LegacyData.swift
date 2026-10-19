import AppKit
import Foundation

/// Keeplight was called Dotpitch until 0.2. Its state (`pending.json`, `disconnected.json`, the
/// journal…) lived in `~/Library/Application Support/Dotpitch`; a pending revert or a display
/// Dotpitch disconnected must not be forgotten by the renamed app, so the folder moves once, before
/// anything reads the state. Five preferences follow separately (`Migration.swift` in the app);
/// onboarding and the brightness-key grant start fresh.
public enum LegacyData {
    public static let folderName = "Dotpitch"
    public static let bundleIdentifier = "io.github.htahaozlu.Dotpitch"

    public enum Outcome: Equatable, Sendable {
        /// The whole old folder became the new one.
        case moved
        /// The new folder already had files: the old files it lacked moved in (`files`), the rest of
        /// the old folder stays where it was.
        case merged(files: [String])
        /// No old folder, or nothing it has that the new one lacks.
        case nothing
        /// The old app is running and still owns its folder; try again next launch (nothing in
        /// Keeplight's folder blocks a later merge).
        case legacyAppRunning
        case failed(String)
    }

    /// Moves `<base>/Dotpitch` to `<base>/Keeplight` when the old folder exists and the old app is
    /// not running. When the new folder already has files (Keeplight ran while Dotpitch still did),
    /// every old file the new folder lacks moves in — above all `pending.json` and
    /// `disconnected.json`; files both have stay as they are. Skipped when `$KEEPLIGHT_SUPPORT_DIR` is set.
    @discardableResult
    public static func migrate(base: URL? = nil, legacyAppRunning: Bool? = nil) -> Outcome {
        if base == nil, let override = ProcessInfo.processInfo.environment["KEEPLIGHT_SUPPORT_DIR"], !override.isEmpty {
            return .nothing
        }
        let fm = FileManager.default
        let target = base.map { $0.appendingPathComponent("Keeplight", isDirectory: true) } ?? Keeplight.supportDirectory
        let source = target.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .nothing }
        if legacyAppRunning ?? isLegacyAppRunning { return .legacyAppRunning }
        do {
            let existing = (try? fm.contentsOfDirectory(atPath: target.path)) ?? []
            if existing.isEmpty {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }  // empty, checked above
                try fm.moveItem(at: source, to: target)
                return .moved
            }
            // Lock files and temporaries are not state.
            let candidates = try fm.contentsOfDirectory(atPath: source.path)
                .filter { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") && !existing.contains($0) }
                .sorted()
            for name in candidates {
                try fm.moveItem(at: source.appendingPathComponent(name), to: target.appendingPathComponent(name))
            }
            return candidates.isEmpty ? .nothing : .merged(files: candidates)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static var isLegacyAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
