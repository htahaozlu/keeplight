import CoreGraphics
import CPrivateDisplay
import Darwin
import Foundation
import IOKit

/// Every private C function DisplayCore uses, resolved at runtime with `dlsym`.
/// Each accessor is nil when the symbol is missing on the running macOS; callers turn
/// that into `DisplayError.unavailable` (or an empty result) instead of crashing.
enum PrivateSymbols {
    enum Framework: String, CaseIterable, Sendable {
        case coreGraphics = "CoreGraphics"
        case skyLight = "SkyLight"
        case displayServices = "DisplayServices"
        case coreDisplay = "CoreDisplay"
        case ioKit = "IOKit"

        var path: String {
            switch self {
            case .coreGraphics: "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
            case .skyLight: "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
            case .displayServices: "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
            case .coreDisplay: "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
            case .ioKit: "/System/Library/Frameworks/IOKit.framework/IOKit"
            }
        }
    }

    /// (symbol, frameworks searched in order, purpose). The first framework is the one
    /// reported on the Transparency page.
    static let table: [(symbol: String, frameworks: [Framework], purpose: String)] = [
        ("CGSGetNumberOfDisplayModes", [.coreGraphics, .skyLight], "Count display modes"),
        ("CGSGetDisplayModeDescriptionOfLength", [.coreGraphics, .skyLight], "List modes, HiDPI included"),
        ("CGSGetCurrentDisplayMode", [.coreGraphics, .skyLight], "Read the current mode"),
        ("CGSConfigureDisplayMode", [.coreGraphics, .skyLight], "Set any mode"),
        ("CGSConfigureDisplayEnabled", [.coreGraphics, .skyLight], "Disconnect and reconnect"),
        ("DisplayServicesGetBrightness", [.displayServices], "Read Apple brightness"),
        ("DisplayServicesSetBrightness", [.displayServices], "Set Apple brightness"),
        ("DisplayServicesCanChangeBrightness", [.displayServices], "Detect Apple brightness"),
        ("CoreDisplay_DisplayCreateInfoDictionary", [.coreDisplay], "Display names and locations"),
        ("IOAVServiceCreateWithService", [.ioKit], "Open a DDC/CI channel"),
        ("IOAVServiceReadI2C", [.ioKit], "DDC/CI read"),
        ("IOAVServiceWriteI2C", [.ioKit], "DDC/CI write"),
        ("IOAVServiceCopyEDID", [.ioKit], "Read EDID over the DDC channel"),
    ]

    nonisolated(unsafe) private static let handles: [Framework: UnsafeMutableRawPointer] = {
        var result: [Framework: UnsafeMutableRawPointer] = [:]
        for framework in Framework.allCases {
            if let handle = dlopen(framework.path, RTLD_LAZY) { result[framework] = handle }
        }
        return result
    }()

    /// Address of `symbol`, searching `frameworks` in order and then every loaded image.
    static func address(_ symbol: String, in frameworks: [Framework]) -> UnsafeMutableRawPointer? {
        for framework in frameworks {
            if let handle = handles[framework], let sym = dlsym(handle, symbol) { return sym }
        }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol)  // RTLD_DEFAULT
    }

    private static func resolve<T>(_ symbol: String, as type: T.Type) -> T? {
        guard let row = table.first(where: { $0.symbol == symbol }),
              let sym = address(symbol, in: row.frameworks) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    // MARK: CoreGraphics / SkyLight

    typealias GetNumberOfDisplayModes = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
    typealias GetDisplayModeDescription = @convention(c) (
        CGDirectDisplayID, Int32, UnsafeMutablePointer<CGSDisplayModeDescription>, Int32) -> Int32
    typealias GetCurrentDisplayMode = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
    typealias ConfigureDisplayMode = @convention(c) (OpaquePointer?, CGDirectDisplayID, Int32) -> Int32
    typealias ConfigureDisplayEnabled = @convention(c) (OpaquePointer?, CGDirectDisplayID, Bool) -> Int32

    static let cgsGetNumberOfDisplayModes = resolve("CGSGetNumberOfDisplayModes", as: GetNumberOfDisplayModes.self)
    static let cgsGetDisplayModeDescription = resolve("CGSGetDisplayModeDescriptionOfLength",
                                                      as: GetDisplayModeDescription.self)
    static let cgsGetCurrentDisplayMode = resolve("CGSGetCurrentDisplayMode", as: GetCurrentDisplayMode.self)
    static let cgsConfigureDisplayMode = resolve("CGSConfigureDisplayMode", as: ConfigureDisplayMode.self)
    static let cgsConfigureDisplayEnabled = resolve("CGSConfigureDisplayEnabled", as: ConfigureDisplayEnabled.self)

    // MARK: DisplayServices

    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    static let displayServicesGetBrightness = resolve("DisplayServicesGetBrightness", as: GetBrightness.self)
    static let displayServicesSetBrightness = resolve("DisplayServicesSetBrightness", as: SetBrightness.self)
    static let displayServicesCanChangeBrightness = resolve("DisplayServicesCanChangeBrightness",
                                                            as: CanChangeBrightness.self)

    // MARK: CoreDisplay

    typealias CreateInfoDictionary = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    static let coreDisplayCreateInfoDictionary = resolve("CoreDisplay_DisplayCreateInfoDictionary",
                                                         as: CreateInfoDictionary.self)

    // MARK: IOKit (IOAVService). Service handles are passed as raw CF pointers.

    typealias AVServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> UnsafeRawPointer?
    typealias AVServiceReadI2C = @convention(c) (
        UnsafeRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias AVServiceWriteI2C = @convention(c) (
        UnsafeRawPointer, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn
    typealias AVServiceCopyEDID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UnsafeRawPointer?>) -> IOReturn

    static let ioAVServiceCreateWithService = resolve("IOAVServiceCreateWithService", as: AVServiceCreate.self)
    static let ioAVServiceReadI2C = resolve("IOAVServiceReadI2C", as: AVServiceReadI2C.self)
    static let ioAVServiceWriteI2C = resolve("IOAVServiceWriteI2C", as: AVServiceWriteI2C.self)
    static let ioAVServiceCopyEDID = resolve("IOAVServiceCopyEDID", as: AVServiceCopyEDID.self)

    /// Error for a call site whose symbol did not resolve.
    static func missing(_ symbol: String) -> DisplayError {
        .unavailable("\(symbol) is missing on this macOS; the feature that needs it is off")
    }
}

/// One undocumented function Keeplight relies on, with its live status on this Mac.
public struct PrivateInterface: Hashable, Identifiable, Codable, Sendable {
    public let symbol: String
    /// Framework that normally exports it (CoreGraphics, DisplayServices, CoreDisplay, IOKit).
    public let framework: String
    /// What Keeplight uses it for.
    public let purpose: String
    /// The symbol was found at runtime; when false the feature that needs it is off.
    public let isResolved: Bool

    public var id: String { symbol }
}

/// Live `dlsym` status of every private symbol, for the Transparency page and `keeplight interfaces`.
public enum PrivateInterfaces {
    public static var all: [PrivateInterface] {
        PrivateSymbols.table.map { row in
            PrivateInterface(symbol: row.symbol, framework: row.frameworks[0].rawValue, purpose: row.purpose,
                             isResolved: PrivateSymbols.address(row.symbol, in: row.frameworks) != nil)
        }
    }

    public static var resolvedCount: Int { all.filter(\.isResolved).count }
}
