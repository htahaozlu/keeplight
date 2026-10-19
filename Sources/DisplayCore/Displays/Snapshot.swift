import CoreGraphics
import Foundation

/// Global position of a display's top-left corner, in points. The main display is at (0, 0).
public struct DisplayOrigin: Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.init(x: Int(point.x.rounded()), y: Int(point.y.rounded()))
    }
}

/// Every display's configuration at one moment, keyed by fingerprint [O§7.1].
public struct DisplaySnapshot: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var fingerprint: String
        public var displayID: CGDirectDisplayID
        public var name: String
        public var modeNumber: Int32?
        /// Mode label at snapshot time (`2560x1440@60 hidpi`), for descriptions.
        public var modeLabel: String?
        public var origin: DisplayOrigin
        public var mirrorSourceFingerprint: String?
        /// False for a display Keeplight software-disconnected.
        public var isEnabled: Bool
        public var isMain: Bool
        public var isBuiltin: Bool

        public init(fingerprint: String, displayID: CGDirectDisplayID, name: String, modeNumber: Int32?,
                    modeLabel: String? = nil, origin: DisplayOrigin, mirrorSourceFingerprint: String? = nil,
                    isEnabled: Bool = true, isMain: Bool = false, isBuiltin: Bool = false) {
            self.fingerprint = fingerprint
            self.displayID = displayID
            self.name = name
            self.modeNumber = modeNumber
            self.modeLabel = modeLabel
            self.origin = origin
            self.mirrorSourceFingerprint = mirrorSourceFingerprint
            self.isEnabled = isEnabled
            self.isMain = isMain
            self.isBuiltin = isBuiltin
        }

        public var ref: DisplayRef { DisplayRef(name: name, fp: fingerprint) }
    }

    public var displays: [Entry]
    public var takenAt: Date

    public init(displays: [Entry], takenAt: Date = Date()) {
        self.displays = displays
        self.takenAt = takenAt
    }

    /// Sorted, de-duplicated fingerprints of every display in the snapshot (enabled or not),
    /// identifying the set of displays on the desk.
    public var signature: String { Self.signature(displays.map(\.fingerprint)) }

    public static func signature(_ fingerprints: [String]) -> String {
        Set(fingerprints).sorted().joined(separator: "|")
    }

    public func entry(for fingerprint: String) -> Entry? {
        displays.first { $0.fingerprint == fingerprint }
    }

    public var main: Entry? { displays.first { $0.isEnabled && $0.isMain } }

    /// Actions that turn `current` into `target`, in execution order: reconnect, disconnect,
    /// stop mirroring, mirror, modes, then origins. Displays absent from `target` are left alone.
    public static func restorePlan(from current: DisplaySnapshot, to target: DisplaySnapshot) -> [RestoreAction] {
        var enable: [RestoreAction] = []
        var disable: [RestoreAction] = []
        var unmirror: [RestoreAction] = []
        var mirror: [RestoreAction] = []
        var modes: [RestoreAction] = []
        for t in target.displays {
            let c = current.entry(for: t.fingerprint)
            let isEnabledNow = c?.isEnabled ?? false
            if t.isEnabled, !isEnabledNow {
                enable.append(.enable(t.ref, displayID: t.displayID))
            } else if !t.isEnabled, isEnabledNow, let c {
                disable.append(.disable(t.ref, displayID: c.displayID))
            }
            guard t.isEnabled else { continue }
            let mirroring = isEnabledNow ? c?.mirrorSourceFingerprint : nil
            if t.mirrorSourceFingerprint != mirroring {
                if let source = t.mirrorSourceFingerprint {
                    mirror.append(.mirror(t.ref, sourceFingerprint: source))
                } else {
                    unmirror.append(.unmirror(t.ref))
                }
            }
            if t.mirrorSourceFingerprint == nil, let n = t.modeNumber, !isEnabledNow || c?.modeNumber != n {
                modes.append(.setMode(t.ref, modeNumber: n, label: t.modeLabel))
            }
        }
        var actions = enable + disable + unmirror + mirror + modes
        let placed = target.displays.filter { $0.isEnabled && $0.mirrorSourceFingerprint == nil }
        let moved = placed.contains { t in
            guard let c = current.entry(for: t.fingerprint), c.isEnabled else { return true }
            return c.origin != t.origin
        }
        if moved, placed.count > 1 || placed.first?.origin != DisplayOrigin(x: 0, y: 0) {
            actions.append(.arrange(Dictionary(placed.map { ($0.fingerprint, $0.origin) },
                                               uniquingKeysWith: { a, _ in a })))
        }
        return actions
    }
}

/// One step of a restore, addressed by fingerprint (display IDs are resolved when executed).
public enum RestoreAction: Hashable, Codable, Sendable, CustomStringConvertible {
    case enable(DisplayRef, displayID: CGDirectDisplayID)
    case disable(DisplayRef, displayID: CGDirectDisplayID)
    case unmirror(DisplayRef)
    case mirror(DisplayRef, sourceFingerprint: String)
    case setMode(DisplayRef, modeNumber: Int32, label: String?)
    /// Fingerprint → origin for every placed display; the one at (0, 0) becomes main.
    case arrange([String: DisplayOrigin])

    public var description: String {
        switch self {
        case .enable(let d, _): "reconnect \(d.name)"
        case .disable(let d, _): "disconnect \(d.name)"
        case .unmirror(let d): "stop mirroring on \(d.name)"
        case .mirror(let d, let source): "mirror \(source) on \(d.name)"
        case .setMode(let d, let n, let label): "set \(d.name) to \(label ?? "mode #\(n)")"
        case .arrange(let origins): "arrange \(origins.count) display\(origins.count == 1 ? "" : "s")"
        }
    }
}

/// Outcome of one restore action.
public struct RestoreStep: Hashable, Codable, Sendable {
    public var action: RestoreAction
    /// nil when the action succeeded.
    public var error: String?

    public init(action: RestoreAction, error: String? = nil) {
        self.action = action
        self.error = error
    }

    public var succeeded: Bool { error == nil }
}

extension DisplayManager {
    /// Current configuration of every online display, plus `disconnected` displays (which are
    /// not online) recorded as disabled.
    public static func snapshot(disconnected: [DisconnectedDisplay] = DisconnectedRegistry.standard.load(),
                                at date: Date = Date()) -> DisplaySnapshot {
        let online = displays()
        let fpByID = Dictionary(online.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { a, _ in a })
        var entries = online.map { d in
            DisplaySnapshot.Entry(
                fingerprint: d.fingerprint, displayID: d.id, name: d.name, modeNumber: d.currentMode?.modeNumber,
                modeLabel: d.currentMode?.label, origin: DisplayOrigin(d.bounds.origin),
                mirrorSourceFingerprint: d.mirrorSource.flatMap { fpByID[$0] },
                isEnabled: true, isMain: d.isMain, isBuiltin: d.isBuiltin)
        }
        let present = Set(entries.map(\.fingerprint))
        for gone in disconnected where !present.contains(gone.fingerprint) {
            entries.append(DisplaySnapshot.Entry(fingerprint: gone.fingerprint, displayID: gone.displayID,
                                                 name: gone.name, modeNumber: nil, origin: DisplayOrigin(x: 0, y: 0),
                                                 isEnabled: false))
        }
        return DisplaySnapshot(displays: entries, takenAt: date)
    }

    /// Best-effort restore of `snapshot`: enabled state, mirroring, modes, then origins, each in
    /// its own configuration. Enabling/disabling never uses `.permanently` (`.forAppOnly` stays
    /// `.forAppOnly`, anything else becomes `.forSession`), so a display can't stay dark across logins.
    @discardableResult
    public static func restore(_ snapshot: DisplaySnapshot, option: CGConfigureOption = .permanently,
                               disconnected: [DisconnectedDisplay] = DisconnectedRegistry.standard.load())
        -> [RestoreStep] {
        execute(DisplaySnapshot.restorePlan(from: self.snapshot(disconnected: disconnected), to: snapshot),
                option: option)
    }

    /// Runs restore actions in order, each in its own configuration, with the same option rules
    /// as `restore` (enabling/disabling is `.forAppOnly` or `.forSession`, never `.permanently`).
    /// Replaying a plan computed once lets a pending restore be re-committed permanently on Keep.
    @discardableResult
    public static func execute(_ plan: [RestoreAction], option: CGConfigureOption = .permanently) -> [RestoreStep] {
        let enableOption: CGConfigureOption = option == .forAppOnly ? .forAppOnly : .forSession
        var ids = Dictionary(displays().map { ($0.fingerprint, $0.id) }, uniquingKeysWith: { a, _ in a })
        func id(_ fp: String) throws -> CGDirectDisplayID {
            guard let id = ids[fp] else { throw DisplayError.displayNotFound(fp) }
            return id
        }
        return plan.map { action in
            do {
                switch action {
                case .enable(_, let displayID):
                    try setEnabled(true, for: displayID, option: enableOption)
                    ids = Dictionary(displays().map { ($0.fingerprint, $0.id) }, uniquingKeysWith: { a, _ in a })
                case .disable(_, let displayID):
                    try setEnabled(false, for: displayID, option: enableOption)
                case .unmirror(let d):
                    try unmirror(id(d.fp), option: option)
                case .mirror(let d, let source):
                    try mirror(id(d.fp), of: id(source), option: option)
                case .setMode(let d, let n, _):
                    try setMode(n, for: id(d.fp), option: option)
                case .arrange(let origins):
                    var byID: [CGDirectDisplayID: DisplayOrigin] = [:]
                    for (fp, origin) in origins { if let i = ids[fp] { byID[i] = origin } }
                    try setOrigins(byID, option: option)
                }
                return RestoreStep(action: action)
            } catch {
                return RestoreStep(action: action, error: String(describing: error))
            }
        }
    }
}

/// Last known-good arrangement per display set, in `known-good.json` [O§7.3].
public struct KnownGoodStore: Sendable {
    public static let standard = KnownGoodStore(directory: Keeplight.supportDirectory)

    public let limit: Int
    private let file: JSONFile<[DisplaySnapshot]>

    public init(directory: URL, limit: Int = 10) {
        self.limit = limit
        file = JSONFile(url: directory.appendingPathComponent("known-good.json"), empty: [])
    }

    /// Most recent first, one per display-set signature.
    public func all() -> [DisplaySnapshot] { file.load() }

    public func snapshot(forSignature signature: String) -> DisplaySnapshot? {
        all().first { $0.signature == signature }
    }

    /// Stores `snapshot` as the known-good setup for its display set, keeping the newest `limit` sets.
    public func save(_ snapshot: DisplaySnapshot) throws {
        try file.update { list in
            list.removeAll { $0.signature == snapshot.signature }
            list.insert(snapshot, at: 0)
            if list.count > limit { list.removeLast(list.count - limit) }
        }
    }
}
