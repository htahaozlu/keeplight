import DisplayCore
import Foundation

// JSON shapes for values that are not `Codable` in DisplayCore or need derived fields.

struct ModeRecord: Encodable {
    let modeNumber: Int32
    let label: String
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let depth: Int
    let density: Double
    let flags: UInt32
    let hiDPI: Bool
    let current: Bool
    /// CRISP/SCALED/NATIVE/SOFT against the panel's native pixels, when known.
    let sharpness: Sharpness?

    init(_ mode: DisplayMode, current: Bool, sharpness: Sharpness? = nil) {
        modeNumber = mode.modeNumber
        label = mode.label
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
        depth = mode.depth
        density = mode.density
        flags = mode.flags
        hiDPI = mode.isHiDPI
        self.current = current
        self.sharpness = sharpness
    }
}

struct EDIDRecord: Encodable {
    struct Timing: Encodable {
        let pixelClockKHz: Int
        let horizontalActive: Int
        let verticalActive: Int
        let refreshRate: Double
    }

    let manufacturerID: String
    let productCode: UInt16
    let serialNumber: UInt32
    let serialString: String?
    let displayName: String?
    let manufactureWeek: Int
    let manufactureYear: Int
    let version: String
    let widthCM: Int
    let heightCM: Int
    let preferredTiming: Timing?
    let extensionCount: Int
    let checksumValid: Bool
    let byteCount: Int
    /// Every byte as lowercase hex, extension blocks included.
    let raw: String

    init(_ edid: EDID) {
        manufacturerID = edid.manufacturerID
        productCode = edid.productCode
        serialNumber = edid.serialNumber
        serialString = edid.serialString
        displayName = edid.displayName
        manufactureWeek = edid.manufactureWeek
        manufactureYear = edid.manufactureYear
        version = "\(edid.version).\(edid.revision)"
        widthCM = edid.widthCM
        heightCM = edid.heightCM
        preferredTiming = edid.preferredTiming.map {
            Timing(pixelClockKHz: $0.pixelClockKHz, horizontalActive: $0.horizontalActive,
                   verticalActive: $0.verticalActive, refreshRate: $0.refreshRate)
        }
        extensionCount = edid.extensionCount
        checksumValid = edid.checksumValid
        byteCount = edid.raw.count
        raw = edid.raw.map { String(format: "%02x", $0) }.joined()
    }
}

struct InfoRecord: Encodable {
    struct BrightnessState: Encodable {
        let backend: BrightnessBackend
        let percent: Int?
        let error: String?
    }

    let index: Int?
    let display: DisplayInfo
    let brightness: BrightnessState?
    let ddc: Bool
    let edid: EDIDRecord?
    let nativePixels: String?
    let sharpness: Sharpness?
}
