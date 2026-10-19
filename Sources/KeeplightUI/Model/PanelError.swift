import DisplayCore
import Foundation

/// What the panel's error row says: one fixed short sentence per failure. Raw CoreGraphics, IOKit
/// and DDC text goes to the log, never to the screen.
enum PanelError {
    static let change = "Couldn't apply that change."
    static let brightness = "Couldn't set brightness."
    static let loginItem = "Couldn't change Open at login."
    static let lastDisplay = "It's your last active screen."
    static let gone = "That display isn't connected."
    static let mode = "That size isn't available."

    static func sentence(for error: Error) -> String {
        guard let error = error as? DisplayError else { return change }
        switch error {
        case .displayNotFound: return gone
        case .modeNotFound: return mode
        case .refused(let reason):
            if reason.localizedCaseInsensitiveContains("last active") { return lastDisplay }
            if reason.localizedCaseInsensitiveContains("pending change") { return Copy.finishPendingFirst }
            return change
        case .coreGraphics, .ioKit, .unavailable, .invalidArgument, .ddc, .notImplemented:
            return change
        }
    }
}

/// At most one error row per `interval`: a failing slider drag queues dozens of failed writes.
struct ErrorRateLimiter {
    let interval: TimeInterval
    private var lastShown: Date?

    init(interval: TimeInterval = 10) { self.interval = interval }

    /// True when a row may be shown at `now`; that counts as showing it.
    mutating func allow(at now: Date) -> Bool {
        if let lastShown, now.timeIntervalSince(lastShown) < interval { return false }
        lastShown = now
        return true
    }
}

enum BrightnessFloor {
    /// The level to write when a panel sits below `floor`; nil when it is at or above it (or unread).
    static func clampTarget(value: Double?, floor: Double) -> Double? {
        guard let value, floor > 0, value < floor - 1e-9 else { return nil }
        return floor
    }
}
