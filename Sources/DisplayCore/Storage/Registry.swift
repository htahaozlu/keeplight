import CoreGraphics
import Foundation

/// A display Keeplight software-disconnected (it is no longer online, so it is remembered here).
public struct DisconnectedDisplay: Codable, Hashable, Identifiable, Sendable {
    public var fingerprint: String
    /// Last known display ID; used to reconnect within the login session.
    public var displayID: CGDirectDisplayID
    public var name: String
    public var disconnectedAt: Date

    public var id: String { fingerprint }
    public var ref: DisplayRef { DisplayRef(name: name, fp: fingerprint) }

    public init(fingerprint: String, displayID: CGDirectDisplayID, name: String, disconnectedAt: Date = Date()) {
        self.fingerprint = fingerprint
        self.displayID = displayID
        self.name = name
        self.disconnectedAt = disconnectedAt
    }
}

/// Displays Keeplight disconnected, keyed by fingerprint, in `disconnected.json`. Shared by the
/// app, the CLI and rescue. Disconnects are `.forSession`, so logout clears them anyway.
public struct DisconnectedRegistry: Sendable {
    public static let standard = DisconnectedRegistry(directory: Keeplight.supportDirectory)

    private let file: JSONFile<[DisconnectedDisplay]>

    public init(directory: URL) {
        file = JSONFile(url: directory.appendingPathComponent("disconnected.json"), empty: [])
    }

    public var fileURL: URL { file.url }

    public func load() -> [DisconnectedDisplay] { file.load() }

    /// Adds or replaces the entry with the same fingerprint.
    public func add(_ display: DisconnectedDisplay) throws {
        try file.update { entries in
            entries.removeAll { $0.fingerprint == display.fingerprint }
            entries.append(display)
        }
    }

    public func remove(fingerprint: String) throws {
        try remove { $0.fingerprint == fingerprint }
    }

    public func remove(where shouldRemove: (DisconnectedDisplay) -> Bool) throws {
        try file.update { $0.removeAll(where: shouldRemove) }
    }

    public func replaceAll(_ entries: [DisconnectedDisplay]) throws {
        try file.update { $0 = entries }
    }

    /// Reconnects every entry with `enable` and forgets those that succeeded.
    /// Returns the entries that are still disconnected.
    @discardableResult
    public func reconnectAll(
        _ enable: (CGDirectDisplayID) throws -> Void = { try DisplayManager.setEnabled(true, for: $0) }
    ) -> [DisconnectedDisplay] {
        let remaining = load().filter { (try? enable($0.displayID)) == nil }
        try? replaceAll(remaining)
        return remaining
    }
}

/// A mirror set Keeplight created (target shows source), so rescue only undoes its own mirrors.
public struct CreatedMirror: Codable, Hashable, Identifiable, Sendable {
    public var target: DisplayRef
    public var sourceFingerprint: String?
    public var createdAt: Date

    public var id: String { target.fp }

    public init(target: DisplayRef, sourceFingerprint: String?, createdAt: Date = Date()) {
        self.target = target
        self.sourceFingerprint = sourceFingerprint
        self.createdAt = createdAt
    }
}

/// Mirrors Keeplight created, keyed by target fingerprint, in `mirrors.json`.
public struct MirrorRegistry: Sendable {
    public static let standard = MirrorRegistry(directory: Keeplight.supportDirectory)

    private let file: JSONFile<[CreatedMirror]>

    public init(directory: URL) {
        file = JSONFile(url: directory.appendingPathComponent("mirrors.json"), empty: [])
    }

    public func load() -> [CreatedMirror] { file.load() }

    public func add(_ mirror: CreatedMirror) throws {
        try file.update { entries in
            entries.removeAll { $0.target.fp == mirror.target.fp }
            entries.append(mirror)
        }
    }

    public func remove(targetFingerprint: String) throws {
        try file.update { $0.removeAll { $0.target.fp == targetFingerprint } }
    }
}

/// Registry updates after a change is applied or kept, shared by transactions and direct
/// (CLI) changes.
enum Bookkeeping {
    static func record(_ kind: JournalEntry.Kind, display: DisplayRef, displayID: CGDirectDisplayID?,
                       after: DisplaySnapshot?, registry: DisconnectedRegistry, mirrors: MirrorRegistry,
                       now: Date) throws {
        switch kind {
        case .disconnect:
            guard let displayID else { return }
            try registry.add(DisconnectedDisplay(fingerprint: display.fp, displayID: displayID,
                                                 name: display.name, disconnectedAt: now))
        case .reconnect:
            try registry.remove(fingerprint: display.fp)
        case .mirror:
            let source = after?.entry(for: display.fp)?.mirrorSourceFingerprint
            try mirrors.add(CreatedMirror(target: display, sourceFingerprint: source, createdAt: now))
        case .unmirror:
            try mirrors.remove(targetFingerprint: display.fp)
        default:
            break
        }
    }

    /// A kept whole-arrangement restore can disconnect, reconnect, mirror and unmirror any
    /// display; diff the snapshots so the registries match what is now on the desk.
    static func recordRestore(before: DisplaySnapshot, after: DisplaySnapshot?, registry: DisconnectedRegistry,
                              mirrors: MirrorRegistry, now: Date) throws {
        guard let after else { return }
        for b in before.displays where b.isEnabled && after.entry(for: b.fingerprint)?.isEnabled != true {
            try registry.add(DisconnectedDisplay(fingerprint: b.fingerprint, displayID: b.displayID,
                                                 name: b.name, disconnectedAt: now))
        }
        for a in after.displays where a.isEnabled {
            try registry.remove(fingerprint: a.fingerprint)
            let was = before.entry(for: a.fingerprint)?.mirrorSourceFingerprint
            if let source = a.mirrorSourceFingerprint, source != was {
                try mirrors.add(CreatedMirror(target: a.ref, sourceFingerprint: source, createdAt: now))
            } else if a.mirrorSourceFingerprint == nil, was != nil {
                try mirrors.remove(targetFingerprint: a.fingerprint)
            }
        }
    }
}
