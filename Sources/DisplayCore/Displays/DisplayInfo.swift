import CoreGraphics
import Foundation

public struct DisplayMode: Hashable, Identifiable, Codable, Sendable {
    public let modeNumber: Int32
    /// Logical size in points.
    public let width: Int
    public let height: Int
    public let refreshRate: Double
    public let depth: Int
    public let density: Double
    public let flags: UInt32

    public var id: Int32 { modeNumber }
    public var isHiDPI: Bool { density > 1.0 }
    /// Valid-mode flag (0x1). Modes without it are listed by CGS but unusable for the desktop.
    public var isUsable: Bool { flags & 0x1 != 0 }
    /// Default-mode flag (0x4, IOKit `kDisplayModeDefaultFlag`): the size macOS picks by default.
    public var isDefault: Bool { flags & 0x4 != 0 }
    /// Native flag (0x0200_0000, IOKit `kDisplayModeNativeFlag`): backing pixels equal the panel's.
    public var isNativeFlagged: Bool { flags & 0x0200_0000 != 0 }
    public var pixelWidth: Int { Int((Double(width) * density).rounded()) }
    public var pixelHeight: Int { Int((Double(height) * density).rounded()) }

    public init(modeNumber: Int32, width: Int, height: Int, refreshRate: Double,
                depth: Int, density: Double, flags: UInt32) {
        self.modeNumber = modeNumber
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.depth = depth
        self.density = density
        self.flags = flags
    }

    /// e.g. `1920x1080@60 hidpi`
    public var label: String {
        var s = "\(width)x\(height)"
        if refreshRate > 0 { s += "@\(Self.format(refreshRate))" }
        if isHiDPI { s += " hidpi" }
        return s
    }

    public static func format(_ hz: Double) -> String {
        hz.rounded() == hz ? String(Int(hz)) : String(format: "%.2f", hz)
    }
}

public struct DisplayInfo: Hashable, Identifiable, Codable, Sendable {
    public let id: CGDirectDisplayID
    public var name: String
    public var vendorID: UInt32
    public var productID: UInt32
    public var serialNumber: UInt32
    public var uuid: String?
    public var isBuiltin: Bool
    public var isMain: Bool
    public var isActive: Bool
    public var isOnline: Bool
    /// Mirror source when this display is a mirror target.
    public var mirrorSource: CGDirectDisplayID?
    public var bounds: CGRect
    public var rotation: Double
    public var currentMode: DisplayMode?
    /// Stable identity across reboots and reconnects (`vendor:product:serial`, see
    /// `Fingerprint`). All persisted state is keyed by it, never by `id`.
    public var fingerprint: String

    public var isMirrorTarget: Bool { mirrorSource != nil }

    /// Name and fingerprint, as stored in the journal and registries.
    public var ref: DisplayRef { DisplayRef(name: name, fp: fingerprint) }

    /// `fingerprint` defaults to the undisambiguated `vendor:product:serial` triple.
    public init(id: CGDirectDisplayID, name: String, vendorID: UInt32, productID: UInt32, serialNumber: UInt32,
                uuid: String?, isBuiltin: Bool, isMain: Bool, isActive: Bool, isOnline: Bool,
                mirrorSource: CGDirectDisplayID?, bounds: CGRect, rotation: Double, currentMode: DisplayMode?,
                fingerprint: String? = nil) {
        self.id = id
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.uuid = uuid
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.isActive = isActive
        self.isOnline = isOnline
        self.mirrorSource = mirrorSource
        self.bounds = bounds
        self.rotation = rotation
        self.currentMode = currentMode
        self.fingerprint = fingerprint
            ?? Fingerprint.base(vendorID: vendorID, productID: productID, serialNumber: serialNumber,
                                serialString: nil)
            ?? uuid ?? "id:\(id)"
    }
}

/// A display as named in persisted records: its name at the time and its fingerprint.
public struct DisplayRef: Hashable, Codable, Sendable {
    public var name: String
    public var fp: String

    public init(name: String, fp: String) {
        self.name = name
        self.fp = fp
    }
}
