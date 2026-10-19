import CoreGraphics
import Foundation

/// Brightness below a monitor's own minimum. DDC brightness 0 is the dimmest the backlight goes,
/// which on most monitors is far brighter than a Mac's built-in screen at its lowest step. The
/// bottom of the app's 0…1 range therefore keeps the backlight at 0 and scales the display's gamma
/// table down instead (`SoftwareDimmer`); the rest of the range is the monitor's own 0…100.
///
///     0 ── handover ───────────────────────────── 1
///     gain darkest…1, DDC 0     gain 1, DDC 0…max
public enum DimmingCurve {
    /// Share of the range below the monitor's minimum: 3 of the 16 brightness-key steps, so the
    /// key grid lands exactly on "backlight at 0, no extra dimming".
    public static let handover = 3.0 / 16
    /// Gamma gain at 0 %: black, like a Mac screen at its lowest. The keys bring it back; quitting
    /// Keeplight or rescue restores the table; waking lifts a black screen to the first step.
    public static let darkest = 0.0
    /// The gain a black screen comes back with after wake: the first key step above black.
    public static let wakeGain = 1.0 / 3

    /// The monitor's level (0…1) and the gamma gain (darkest…1) for an app level.
    public static func split(_ value: Double) -> (hardware: Double, gain: Double) {
        let v = min(max(value, 0), 1)
        if v >= handover { return ((v - handover) / (1 - handover), 1) }
        return (0, darkest + (1 - darkest) * v / handover)
    }

    /// The app level for a monitor level and a gain (inverse of `split`). A monitor above 0 (its
    /// own buttons, the CLI) wins over a stale gain.
    public static func combine(hardware: Double, gain: Double) -> Double {
        let h = min(max(hardware, 0), 1)
        if h > 0.0005 || gain >= 1 { return handover + (1 - handover) * h }
        let g = min(max(gain, darkest), 1)
        return handover * (g - darkest) / (1 - darkest)
    }

    /// A level saved before combined dimming existed (the monitor's own 0…1), on the new range.
    public static func fromHardware(_ value: Double) -> Double { combine(hardware: value, gain: 1) }
}

/// The display's gamma transfer table, behind a seam for tests.
public protocol GammaTables: Sendable {
    func read(_ id: CGDirectDisplayID) -> GammaTable?
    func write(_ table: GammaTable, to id: CGDirectDisplayID) -> Bool
}

public struct GammaTable: Equatable, Sendable {
    public var red: [CGGammaValue]
    public var green: [CGGammaValue]
    public var blue: [CGGammaValue]

    public init(red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Every entry times `gain`: the curve keeps its shape (calibration survives), only darker.
    public func scaled(by gain: Double) -> GammaTable {
        let g = CGGammaValue(min(max(gain, 0), 1))
        return GammaTable(red: red.map { $0 * g }, green: green.map { $0 * g }, blue: blue.map { $0 * g })
    }
}

/// CoreGraphics' public transfer-table calls. macOS puts the user's ColorSync tables back by
/// itself when the process exits, so a crash cannot leave a screen dimmed.
public struct LiveGammaTables: GammaTables {
    public init() {}

    public func read(_ id: CGDirectDisplayID) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success, count > 0 else {
            return nil
        }
        let n = Int(count)
        return GammaTable(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    public func write(_ table: GammaTable, to id: CGDirectDisplayID) -> Bool {
        let n = UInt32(min(table.red.count, table.green.count, table.blue.count))
        return CGSetDisplayTransferByTable(id, n, table.red, table.green, table.blue) == .success
    }
}

/// Per-display gamma gain. The display's own table is captured before the first dimming and put
/// back at gain 1, on `resetAll()` (quit, rescue, erase) and when the display goes away. Thread
/// safe: brightness writes arrive on the write throttle's queue.
public final class SoftwareDimmer: @unchecked Sendable {
    private let tables: any GammaTables
    private let lock = NSLock()
    private var gains: [CGDirectDisplayID: Double] = [:]
    private var originals: [CGDirectDisplayID: GammaTable] = [:]
    /// The last monitor level written per display, so a key press inside the dimmed range does not
    /// send DDC 0 again.
    private var hardware: [CGDirectDisplayID: Double] = [:]

    public init(tables: any GammaTables = LiveGammaTables()) {
        self.tables = tables
    }

    public func gain(for id: CGDirectDisplayID) -> Double { lock.withLock { gains[id] ?? 1 } }

    public func setGain(_ gain: Double, for id: CGDirectDisplayID) {
        lock.withLock { applyLocked(min(max(gain, 0), 1), for: id) }
    }

    /// Whether `level` differs from the last monitor level written for `id` (and remembers it).
    func hardwareChanged(to level: Double, for id: CGDirectDisplayID) -> Bool {
        lock.withLock {
            if let last = hardware[id], abs(last - level) < 0.0005 { return false }
            hardware[id] = level
            return true
        }
    }

    func forgetHardware(for id: CGDirectDisplayID) { _ = lock.withLock { hardware.removeValue(forKey: id) } }

    /// After wake or a display reconfiguration macOS may have reloaded the tables (apply them
    /// again) and the monitor may have reset its backlight (send the next level even if unchanged).
    /// `liftingBelow`: gains under it come back at it (wake: a black screen looks like a dead Mac).
    public func reapply(liftingBelow minimum: Double = 0) {
        lock.withLock {
            hardware = [:]
            for (id, gain) in gains where gain < minimum { gains[id] = minimum }
            for (id, gain) in gains where gain < 1 {
                if let original = originals[id] { _ = tables.write(original.scaled(by: gain), to: id) }
            }
        }
    }

    /// Every display back to its own table.
    public func resetAll() {
        lock.withLock {
            for id in Array(gains.keys) { applyLocked(1, for: id) }
            hardware = [:]
        }
    }

    /// A display that went away: forget it (macOS rebuilds its table when it returns).
    public func forget(_ id: CGDirectDisplayID) {
        lock.withLock {
            gains[id] = nil
            originals[id] = nil
            hardware[id] = nil
        }
    }

    private func applyLocked(_ gain: Double, for id: CGDirectDisplayID) {
        let current = gains[id] ?? 1
        if gain >= 1 {
            guard current < 1 else { return }
            if let original = originals[id] { _ = tables.write(original, to: id) }
            gains[id] = nil
            originals[id] = nil
            return
        }
        if originals[id] == nil {
            guard let table = tables.read(id) else { return }
            originals[id] = table
        }
        guard let original = originals[id], tables.write(original.scaled(by: gain), to: id) else { return }
        gains[id] = gain
    }
}

/// A DDC control with the dimmed bottom range (`DimmingCurve`). Only the app uses it: the CLI
/// keeps the monitor's own 0…100, since a gamma change would end with the CLI's process.
public struct DimmingBrightness: BrightnessControl {
    public let base: any BrightnessControl
    public let dimmer: SoftwareDimmer

    public init(base: any BrightnessControl, dimmer: SoftwareDimmer) {
        self.base = base
        self.dimmer = dimmer
    }

    public var backend: BrightnessBackend { base.backend }
    public var displayID: CGDirectDisplayID { base.displayID }
    public var mechanism: String { base.mechanism + " + gamma" }

    public func brightness() throws -> Double {
        DimmingCurve.combine(hardware: try base.brightness(), gain: dimmer.gain(for: displayID))
    }

    public func setBrightness(_ value: Double) throws {
        let (hardware, gain) = DimmingCurve.split(value)
        // Brighter: lift the gamma first, then the backlight; darker: the other way round.
        if gain >= 1 { dimmer.setGain(1, for: displayID) }
        if dimmer.hardwareChanged(to: hardware, for: displayID) {
            do {
                try base.setBrightness(hardware)
            } catch {
                dimmer.forgetHardware(for: displayID)
                throw error
            }
        }
        if gain < 1 { dimmer.setGain(gain, for: displayID) }
    }
}
