import CoreGraphics
import Foundation

/// Input rules for the brightness slider [O§5.1], in normalized units (0...1). Pure, so the
/// app's slider and tests share them.
public enum BrightnessPolicy {
    /// Values a drag snaps to.
    public static let detents: [Double] = [0, 0.5, 1]
    /// Snap window around each detent (±1 %).
    public static let detentWindow = 0.01
    /// Minimum while the display is the only active one, so a stray gesture can't black out the desk.
    public static let onlyScreenFloor = 0.02
    /// VoiceOver increment / decrement.
    public static let accessibilityStep = 0.05

    public static func clamp(_ value: Double, floor: Double = 0) -> Double {
        min(1, max(floor, value))
    }

    /// The detent within ±1 % of `value`, if any.
    public static func detent(near value: Double) -> Double? {
        detents.first { abs(value - $0) <= detentWindow + 1e-9 }
    }

    /// Relative drag: `start + dx / width`, snapped to a detent, then held at `floor`.
    /// Returns the detent only when the result sits on it.
    public static func dragged(from start: Double, dx: Double, width: Double,
                               floor: Double) -> (value: Double, detent: Double?) {
        guard width > 0 else { return (clamp(start, floor: floor), nil) }
        let raw = clamp(start + dx / width)
        let snapped = detent(near: raw) ?? raw
        let value = clamp(snapped, floor: floor)
        return (value, value == snapped ? detent(near: raw) : nil)
    }

    /// One scroll event. `amount` is points for precise devices (trackpad, Magic Mouse) and
    /// notches for wheels; positive is brighter. Trackpad: 1 % per 3 pt. Wheel: 2 % per notch.
    /// ⌥ (`fine`) × 0.25, ⇧ (`coarse`) × 5.
    public static func scrollStep(_ amount: Double, precise: Bool, fine: Bool, coarse: Bool) -> Double {
        let base: Double
        if precise {
            base = amount / 3 * 0.01
        } else {
            base = amount == 0 ? 0 : (amount > 0 ? 0.02 : -0.02)
        }
        return base * (fine ? 0.25 : coarse ? 5 : 1)
    }

    /// Arrow keys: 1 %, ⇧ 10 %, ⌥ 0.25 %.
    public static func keyStep(fine: Bool, coarse: Bool) -> Double {
        fine ? 0.0025 : coarse ? 0.10 : 0.01
    }

    /// Whole percent shown in the readout and journal.
    public static func percent(_ value: Double) -> Int {
        Int((clamp(value) * 100).rounded())
    }

    /// Brightness keys move in 16 steps over the range, like macOS; ⌥⇧ moves in quarter steps.
    public static let keySteps = 16
    public static let fineKeySteps = 64

    /// The level after one brightness-key press: snap `value` to the step grid, move one step,
    /// then hold at `floor`.
    public static func keyed(from value: Double, up: Bool, fine: Bool, floor: Double = 0) -> Double {
        let steps = Double(fine ? fineKeySteps : keySteps)
        let position = (clamp(value) * steps).rounded()
        return clamp((position + (up ? 1 : -1)) / steps, floor: floor)
    }
}

/// Brightness restore after wake [O§7.6]: DDC monitors often come back at their factory level.
public enum WakeRestorePolicy {
    /// Differences up to this many whole percent are left alone.
    public static let tolerancePercent = 2
    /// Older remembered values are not restored.
    public static let maxAge: TimeInterval = 7 * 86_400

    /// Restore once when the monitor reports more than 2 % away from the last value Keeplight
    /// wrote, and that value is less than 7 days old.
    public static func shouldRestore(read: Double, lastWritten: Double, writtenAt: Date, now: Date) -> Bool {
        abs(BrightnessPolicy.percent(read) - BrightnessPolicy.percent(lastWritten)) > tolerancePercent
            && now.timeIntervalSince(writtenAt) < maxAge
    }
}

/// After wake or hotplug, hardware is left alone until display reconfiguration has been quiet
/// for 1.5 s, or 8 s have passed [O§7.6]. Pure: the caller supplies monotonic times.
public struct SettleWindow: Hashable, Sendable {
    public static let quiet: TimeInterval = 1.5
    public static let cap: TimeInterval = 8
    /// Delays between brightness re-probes after settling (at most 4 tries per display).
    public static let probeBackoff: [TimeInterval] = [0, 0.5, 1, 2]

    public let start: TimeInterval
    public private(set) var lastEvent: TimeInterval

    public init(start: TimeInterval) {
        self.start = start
        lastEvent = start
    }

    /// A reconfiguration (or another wake) at `time` restarts the quiet period.
    public mutating func note(_ time: TimeInterval) {
        lastEvent = max(lastEvent, time)
    }

    public var deadline: TimeInterval { min(lastEvent + Self.quiet, start + Self.cap) }

    public func isSettled(at time: TimeInterval) -> Bool { time >= deadline }
}

/// Geometry of the desk map and the order shared by the panel, the map and Identify.
public enum DeskLayout {
    /// Left → right, then top → bottom, by each display's global top-left corner (y down).
    public static func order<ID>(_ items: [(id: ID, bounds: CGRect)]) -> [ID] {
        items.enumerated().sorted { a, b in
            let (ra, rb) = (a.element.bounds, b.element.bounds)
            if ra.minX != rb.minX { return ra.minX < rb.minX }
            if ra.minY != rb.minY { return ra.minY < rb.minY }
            return a.offset < b.offset
        }.map(\.element.id)
    }

    /// `rects` scaled uniformly (true relative sizes and positions) and centered in `size`
    /// minus `inset` on every side. Order is preserved.
    public static func fit(_ rects: [CGRect], in size: CGSize, inset: CGFloat) -> [CGRect] {
        guard let first = rects.first else { return [] }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let available = CGSize(width: max(0, size.width - 2 * inset), height: max(0, size.height - 2 * inset))
        guard union.width > 0, union.height > 0 else { return rects.map { _ in .zero } }
        let scale = min(available.width / union.width, available.height / union.height)
        let offset = CGPoint(x: (size.width - union.width * scale) / 2, y: (size.height - union.height * scale) / 2)
        return rects.map { r in
            CGRect(x: offset.x + (r.minX - union.minX) * scale, y: offset.y + (r.minY - union.minY) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
    }
}
