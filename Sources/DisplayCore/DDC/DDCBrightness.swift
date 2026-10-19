import CoreGraphics
import Foundation

public struct DDCBrightness: BrightnessControl {
    public let displayID: CGDirectDisplayID
    public var backend: BrightnessBackend { .ddc }
    public let maximum: UInt16

    private let ddc: DDCService

    /// Probes VCP 0x10 once; nil when the display has no DDC channel or reports a
    /// zero maximum (brightness not exposed over DDC on that input/firmware).
    public init?(display: DisplayInfo) {
        guard let ddc = DDCService(display: display),
              let reply = try? ddc.read(.brightness), reply.maximum > 0 else { return nil }
        self.ddc = ddc
        self.displayID = display.id
        self.maximum = reply.maximum
    }

    public func brightness() throws -> Double {
        let current = try ddc.read(.brightness).current
        return min(1, Double(current) / Double(maximum))
    }

    public func setBrightness(_ value: Double) throws {
        let raw = (min(max(value, 0), 1) * Double(maximum)).rounded()
        try ddc.write(.brightness, value: UInt16(raw))
    }
}
