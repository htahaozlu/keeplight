import CoreGraphics
import DisplayCore
import Foundation

struct PixelSize: Hashable, Sendable {
    let width: Int
    let height: Int

    init(_ size: (width: Int, height: Int)) {
        width = size.width
        height = size.height
    }

    var tuple: (width: Int, height: Int) { (width, height) }
}

/// One active display as the panel shows it, in desk order.
struct DisplayItem: Identifiable, Equatable {
    let info: DisplayInfo
    let index: Int
    let modes: [DisplayMode]
    let native: PixelSize?
    let isPhysical: Bool
    let isNew: Bool
    /// Usable modes, one per label (`Show All…`).
    let usableModes: [DisplayMode]
    /// The ≤ 6 sizes in the resolution menu.
    let recommended: [DisplayMode]

    var id: CGDirectDisplayID { info.id }
    var fingerprint: String { info.fingerprint }
    var current: DisplayMode? { info.currentMode }

    init(info: DisplayInfo, index: Int, modes: [DisplayMode], native: PixelSize?, isPhysical: Bool, isNew: Bool) {
        self.info = info
        self.index = index
        self.modes = modes
        self.native = native
        self.isPhysical = isPhysical
        self.isNew = isNew
        usableModes = DisplayManager.uniqueModes(modes, current: info.currentMode).filter(\.isUsable)
        recommended = native.map {
            DisplayManager.recommendedModes(modes, current: info.currentMode, native: $0.tuple)
        } ?? []
    }

    func sharpness(_ mode: DisplayMode) -> Sharpness? { native.map { mode.sharpness(native: $0.tuple) } }

    /// Blurry: stretched by the monitor or the GPU without HiDPI (`soft`). macOS's own HiDPI
    /// "Looks like" sizes (`scaled`: drawn at 2× and resampled) are not marked: on a 4K panel
    /// 2560 × 1440 is the sharp everyday choice. Unknown native: false.
    func isSoft(_ mode: DisplayMode) -> Bool {
        switch sharpness(mode) {
        case .soft?: true
        case .scaled?, .crisp?, .native?, nil: false
        }
    }

    /// The refresh rate is worth printing for `mode`: the display offers this size at several rates.
    func hasRefreshChoice(_ mode: DisplayMode) -> Bool {
        Set(usableModes.filter { $0.width == mode.width && $0.height == mode.height }
            .map { Int($0.refreshRate.rounded()) }).count > 1
    }
}

/// Brightness backend state per display.
enum BrightnessState {
    case probing
    case unavailable
    /// `value` is nil when the current level could not be read; `readMs` is the probe latency.
    case available(control: any BrightnessControl, value: Double?, readMs: Int?)

    var control: (any BrightnessControl)? {
        if case .available(let control, _, _) = self { return control }
        return nil
    }

    var value: Double? {
        if case .available(_, let value, _) = self { return value }
        return nil
    }
}

/// The live, unconfirmed change, as the Keep card shows it.
struct PendingInfo: Identifiable, Equatable {
    let id: String
    let kind: TransactionKind
    let displayName: String
    let title: String
    let detail: String?
    let displayFingerprint: String
    let before: String
    let startedAt: Date
    let deadline: Date

    var duration: TimeInterval { max(1, deadline.timeIntervalSince(startedAt)) }

    func secondsLeft(at date: Date) -> Int { max(0, Int(ceil(deadline.timeIntervalSince(date)))) }
}

/// How the Keep card leaves the screen.
enum RingPhase: Equatable {
    case live
    case sealed(Date)
    case reverted(Date)
    /// The restore itself failed; Rescue runs next.
    case revertFailed(Date)
}

extension RevertResult {
    /// At least one restore step failed, so the display may not be back where it was.
    var hadFailures: Bool { steps.contains { !$0.succeeded } }
}

/// One row above the sections for 60 s (wake restore, rescue, unwanted revert).
struct Receipt: Equatable {
    enum Undo: Equatable {
        /// Undo this journal entry.
        case entry(String)
        /// Undo the last rescue as a whole.
        case rescue
    }

    var text: String
    var undo: Undo?
    var expires: Date
}

/// The Settings window's toolbar tabs, in order (⌘1–⌘3).
enum SettingsTab: String, Hashable, CaseIterable {
    case general, displays, about

    var title: String {
        switch self {
        case .general: "General"
        case .displays: "Displays"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .displays: "display"
        case .about: "info.circle"
        }
    }
}

/// The latest journal entry Undo can reverse (⌘Z, the status item's menu).
struct UndoCandidate: Equatable {
    let entry: JournalEntry
    /// Tooltip naming the change.
    let label: String
}

/// Settings › Displays passport lines [O§6.5].
struct Passport: Equatable, Sendable {
    var made: String?
    var size: String?
    var panel: String?
    var identity: String?
    var brightness: String?
    var modes: String?
}

/// Diagnostics for one display, with when it was taken.
struct DiagnosisState: Equatable {
    var report: DiagnosticReport?
    var running: Bool
}

extension DisplayMode {
    /// "2560 × 1440"
    var sizeText: String { "\(width) × \(height)" }
}

enum Format {
    /// "2560x1440@60 hidpi" → "2560 × 1440"; other text passes through.
    static func modeLabel(_ label: String?) -> String {
        guard let label else { return "?" }
        let size = label.split(separator: "@").first.map(String.init) ?? label
        let parts = size.split(separator: "x")
        guard parts.count == 2, Int(parts[0]) != nil, Int(parts[1].prefix { $0.isNumber }) != nil else { return label }
        return "\(parts[0]) × \(parts[1].prefix { $0.isNumber })"
    }

    static func hz(_ rate: Double) -> String { DisplayMode.format(rate) }

    /// "40%" → 0.40
    static func percentValue(_ text: String?) -> Double? {
        guard let text, let n = Double(text.replacingOccurrences(of: "%", with: "")) else { return nil }
        return n / 100
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}
