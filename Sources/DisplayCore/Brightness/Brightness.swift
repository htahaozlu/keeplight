import CoreGraphics
import Foundation

public enum BrightnessBackend: String, Codable, CaseIterable, Sendable {
    /// DisplayServices: built-in panels and Apple displays.
    case apple
    /// DDC/CI VCP 0x10 over IOAVService.
    case ddc

    /// The write call, for the journal and Raw mode.
    public var mechanism: String {
        switch self {
        case .apple: "DisplayServicesSetBrightness"
        case .ddc: "DDC VCP 0x10"
        }
    }
}

/// Normalized (0...1) brightness for one display.
public protocol BrightnessControl: Sendable {
    var backend: BrightnessBackend { get }
    var displayID: CGDirectDisplayID { get }
    /// The write call, for the journal (the backend's, unless the control adds something).
    var mechanism: String { get }
    func brightness() throws -> Double
    func setBrightness(_ value: Double) throws
}

extension BrightnessControl {
    public var mechanism: String { backend.mechanism }
}

public enum Brightness {
    /// Best available backend: apple → ddc, trying `preferring` first. May block for
    /// a DDC probe (~100 ms); call off the main thread.
    public static func control(for display: DisplayInfo,
                               preferring preferred: BrightnessBackend? = nil) -> (any BrightnessControl)? {
        let order = (preferred.map { [$0] } ?? []) + BrightnessBackend.allCases.filter { $0 != preferred }
        for backend in order {
            if let control = make(backend, for: display) { return control }
        }
        return nil
    }

    public static func make(_ backend: BrightnessBackend, for display: DisplayInfo) -> (any BrightnessControl)? {
        switch backend {
        case .apple: AppleBrightness(displayID: display.id)
        case .ddc: DDCBrightness(display: display)
        }
    }
}

public struct AppleBrightness: BrightnessControl {
    public let displayID: CGDirectDisplayID
    public var backend: BrightnessBackend { .apple }

    public init?(displayID: CGDirectDisplayID) {
        guard let can = PrivateSymbols.displayServicesCanChangeBrightness,
              PrivateSymbols.displayServicesGetBrightness != nil,
              PrivateSymbols.displayServicesSetBrightness != nil,
              can(displayID) else { return nil }
        self.displayID = displayID
    }

    public func brightness() throws -> Double {
        var value: Float = 0
        let rc = PrivateSymbols.displayServicesGetBrightness!(displayID, &value)
        guard rc == 0 else { throw DisplayError.unavailable("DisplayServicesGetBrightness rc=\(rc)") }
        return Double(value)
    }

    public func setBrightness(_ value: Double) throws {
        let rc = PrivateSymbols.displayServicesSetBrightness!(displayID, Float(min(max(value, 0), 1)))
        guard rc == 0 else { throw DisplayError.unavailable("DisplayServicesSetBrightness rc=\(rc)") }
    }
}
