import CoreGraphics
import Foundation

extension BrightnessBackend {
    /// Shortest interval between two brightness writes [O§5.1]: 16 ms for DisplayServices,
    /// 100 ms for DDC/CI (monitors drop or queue faster writes).
    public var minimumWriteInterval: TimeInterval {
        switch self {
        case .apple: 0.016
        case .ddc: 0.1
        }
    }
}

/// Leading + trailing rate limit for one display's brightness writes. Pure: the caller
/// supplies monotonic timestamps (e.g. `ProcessInfo.processInfo.systemUptime`) and schedules
/// the trailing call.
///
/// The first value after a quiet period is written at once (leading). Values arriving within
/// `interval` of the last write are coalesced (latest wins) and written by `fire(at:)` once the
/// interval has passed (trailing), so the final value is always written.
public struct WriteThrottle: Hashable, Sendable {
    public enum Decision: Hashable, Sendable {
        /// Write this value now.
        case write(Double)
        /// Nothing to write now; call `fire(at:)` at this time.
        case schedule(at: TimeInterval)
        /// Coalesced into a trailing write that is already scheduled.
        case coalesced
        /// Nothing pending.
        case idle
    }

    public let interval: TimeInterval
    public private(set) var lastWrite: TimeInterval?
    public private(set) var pending: Double?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    public init(backend: BrightnessBackend) {
        self.init(interval: backend.minimumWriteInterval)
    }

    public mutating func submit(_ value: Double, at now: TimeInterval) -> Decision {
        guard let last = lastWrite, now - last < interval else {
            lastWrite = now
            pending = nil
            return .write(value)
        }
        let alreadyScheduled = pending != nil
        pending = value
        return alreadyScheduled ? .coalesced : .schedule(at: last + interval)
    }

    /// The trailing write. Early calls (timer jitter) reschedule instead of writing.
    public mutating func fire(at now: TimeInterval) -> Decision {
        guard let value = pending else { return .idle }
        if let last = lastWrite, now - last < interval - 0.0005 { return .schedule(at: last + interval) }
        pending = nil
        lastWrite = now
        return .write(value)
    }
}

/// Throttled brightness writes for the app: one serial queue, one `WriteThrottle` per display
/// with the backend's interval. Errors are reported through `onError`.
public final class BrightnessWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.htahaozlu.Keeplight.brightness", qos: .userInitiated)
    private var throttles: [CGDirectDisplayID: WriteThrottle] = [:]
    private var controls: [CGDirectDisplayID: any BrightnessControl] = [:]

    public init() {}

    public func set(_ value: Double, via control: any BrightnessControl,
                    onError: @escaping @Sendable (String) -> Void, onSuccess: (@Sendable () -> Void)? = nil) {
        queue.async {
            let id = control.displayID
            self.controls[id] = control
            var throttle = self.throttles[id] ?? WriteThrottle(backend: control.backend)
            let decision = throttle.submit(value, at: ProcessInfo.processInfo.systemUptime)
            self.throttles[id] = throttle
            self.handle(decision, for: id, onError: onError, onSuccess: onSuccess)
        }
    }

    private func handle(_ decision: WriteThrottle.Decision, for id: CGDirectDisplayID,
                        onError: @escaping @Sendable (String) -> Void, onSuccess: (@Sendable () -> Void)?) {
        switch decision {
        case .write(let value):
            do {
                try controls[id]?.setBrightness(value)
                onSuccess?()
            } catch { onError(String(describing: error)) }
        case .schedule(let at):
            let delay = max(0, at - ProcessInfo.processInfo.systemUptime)
            queue.asyncAfter(deadline: .now() + delay) {
                guard var throttle = self.throttles[id] else { return }
                let next = throttle.fire(at: ProcessInfo.processInfo.systemUptime)
                self.throttles[id] = throttle
                self.handle(next, for: id, onError: onError, onSuccess: onSuccess)
            }
        case .coalesced, .idle:
            break
        }
    }
}
