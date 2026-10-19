import AppKit
import CoreGraphics
import CPrivateDisplay
import Foundation

/// Inventory and configuration of online displays.
///
/// Configuration calls take a `CGConfigureOption`: `.permanently` (the default) persists the
/// change, `.forSession` lasts until logout, and `.forAppOnly` is dropped by WindowServer
/// when this process exits (used while a transaction is pending).
public enum DisplayManager {
    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public static func displays() -> [DisplayInfo] {
        infos(for: onlineDisplayIDs())
    }

    /// Details for one display. The fingerprint is disambiguated against every online display.
    public static func info(for id: CGDirectDisplayID) -> DisplayInfo {
        let online = onlineDisplayIDs()
        let all = infos(for: online.contains(id) ? online : online + [id])
        return all.first { $0.id == id } ?? baseInfo(for: id)
    }

    private static func infos(for ids: [CGDirectDisplayID]) -> [DisplayInfo] {
        let base = ids.map(baseInfo(for:))
        let inputs = base.map {
            Fingerprint.Input(displayID: $0.id, vendorID: $0.vendorID, productID: $0.productID,
                              serialNumber: $0.serialNumber, serialString: IdentityCache.serialString(for: $0),
                              uuid: $0.uuid)
        }
        let byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fingerprints = Fingerprint.assign(inputs) { id in byID[id].flatMap(IdentityCache.location(for:)) }
        return base.map { info in
            var info = info
            if let fp = fingerprints[info.id] { info.fingerprint = fp }
            return info
        }
    }

    private static func baseInfo(for id: CGDirectDisplayID) -> DisplayInfo {
        let mirror = CGDisplayMirrorsDisplay(id)
        return DisplayInfo(
            id: id,
            name: name(for: id),
            vendorID: CGDisplayVendorNumber(id),
            productID: CGDisplayModelNumber(id),
            serialNumber: CGDisplaySerialNumber(id),
            uuid: CGDisplayCreateUUIDFromDisplayID(id).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            },
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isMain: CGDisplayIsMain(id) != 0,
            isActive: CGDisplayIsActive(id) != 0,
            isOnline: CGDisplayIsOnline(id) != 0,
            mirrorSource: mirror == kCGNullDirectDisplay ? nil : mirror,
            bounds: CGDisplayBounds(id),
            rotation: CGDisplayRotation(id),
            currentMode: currentMode(for: id)
        )
    }

    public static func name(for id: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen.localizedName
        }
        if let create = PrivateSymbols.coreDisplayCreateInfoDictionary,
           let info = create(id)?.takeRetainedValue() as? [String: Any],
           let names = info["DisplayProductName"] as? [String: String],
           let name = names["en_US"] ?? names.values.first {
            return name
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }

    // MARK: Modes

    /// Every CGS mode, HiDPI duplicates included; empty when the CGS symbols are missing.
    public static func modes(for id: CGDirectDisplayID) -> [DisplayMode] {
        guard let getCount = PrivateSymbols.cgsGetNumberOfDisplayModes else { return [] }
        var count: Int32 = 0
        guard getCount(id, &count) == CGError.success.rawValue, count > 0 else { return [] }
        return (0..<count).compactMap { mode(at: $0, for: id) }
    }

    public static func currentMode(for id: CGDirectDisplayID) -> DisplayMode? {
        guard let getCurrent = PrivateSymbols.cgsGetCurrentDisplayMode else { return nil }
        var number: Int32 = 0
        guard getCurrent(id, &number) == CGError.success.rawValue else { return nil }
        return mode(at: number, for: id)
    }

    private static func mode(at index: Int32, for id: CGDirectDisplayID) -> DisplayMode? {
        guard let describe = PrivateSymbols.cgsGetDisplayModeDescription else { return nil }
        var desc = CGSDisplayModeDescription()
        let size = Int32(MemoryLayout<CGSDisplayModeDescription>.size)
        guard describe(id, index, &desc, size) == CGError.success.rawValue else { return nil }
        return DisplayMode(
            modeNumber: Int32(bitPattern: desc.modeNumber),
            width: Int(desc.width),
            height: Int(desc.height),
            refreshRate: Double(desc.freq),
            depth: Int(desc.depth),
            density: desc.density > 0 ? Double(desc.density) : 1.0,
            flags: desc.flags
        )
    }

    /// Finds a usable mode from `WxH[@Hz][ hidpi]`. Prefers HiDPI when requested,
    /// otherwise non-HiDPI, then the highest refresh rate and depth, then the lowest number.
    public static func findMode(_ spec: String, for id: CGDirectDisplayID) throws -> DisplayMode {
        let parsed = try ModeSpec(spec)
        let candidates = modes(for: id).filter { mode in
            mode.isUsable && mode.width == parsed.width && mode.height == parsed.height
                && (parsed.refreshRate.map { abs(mode.refreshRate - $0) < 0.5 } ?? true)
                && (parsed.hiDPI.map { $0 == mode.isHiDPI } ?? true)
        }
        let best = candidates.max { a, b in
            if parsed.hiDPI == nil, a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            if a.refreshRate != b.refreshRate { return a.refreshRate < b.refreshRate }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.modeNumber > b.modeNumber
        }
        guard let best else { throw DisplayError.modeNotFound(spec) }
        return best
    }

    /// One usable mode per label for menus and listings: the current mode when it shares
    /// the label, else the deepest, then the lowest number. Ordered HiDPI first, then by
    /// width, height and refresh rate descending.
    public static func uniqueModes(_ modes: [DisplayMode], current: DisplayMode?) -> [DisplayMode] {
        var byLabel: [String: DisplayMode] = [:]
        for mode in modes where mode.isUsable || mode.modeNumber == current?.modeNumber {
            guard let existing = byLabel[mode.label] else { byLabel[mode.label] = mode; continue }
            if existing.modeNumber == current?.modeNumber { continue }
            if mode.modeNumber == current?.modeNumber
                || mode.depth > existing.depth
                || (mode.depth == existing.depth && mode.modeNumber < existing.modeNumber) {
                byLabel[mode.label] = mode
            }
        }
        return byLabel.values.sorted { a, b in
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            return a.modeNumber < b.modeNumber
        }
    }

    public static func setMode(_ modeNumber: Int32, for id: CGDirectDisplayID,
                               option: CGConfigureOption = .permanently) throws {
        guard let configureMode = PrivateSymbols.cgsConfigureDisplayMode else {
            throw PrivateSymbols.missing("CGSConfigureDisplayMode")
        }
        try configure("set mode", option: option) { config in
            CGError(rawValue: configureMode(config, id, modeNumber)) ?? .failure
        }
    }

    // MARK: Arrangement

    /// Moves `id` to the global origin, making it the main display.
    public static func setMain(_ id: CGDirectDisplayID, option: CGConfigureOption = .permanently) throws {
        guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else {
            throw DisplayError.refused("display \(id) is a mirror target; set its mirror source as main instead")
        }
        let origin = CGDisplayBounds(id).origin
        try configure("set main", option: option) { config in
            for other in onlineDisplayIDs() where CGDisplayMirrorsDisplay(other) == kCGNullDirectDisplay {
                let b = CGDisplayBounds(other)
                let err = CGConfigureDisplayOrigin(config, other,
                                                   Int32(b.origin.x - origin.x),
                                                   Int32(b.origin.y - origin.y))
                if err != .success { return err }
            }
            return .success
        }
    }

    /// Places displays at global origins in one configuration; the one at (0, 0) becomes main.
    public static func setOrigins(_ origins: [CGDirectDisplayID: DisplayOrigin],
                                  option: CGConfigureOption = .permanently) throws {
        guard !origins.isEmpty else { return }
        try configure("arrange", option: option) { config in
            for (id, origin) in origins.sorted(by: { $0.key < $1.key }) {
                let err = CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
                if err != .success { return err }
            }
            return .success
        }
    }

    public static func mirror(_ target: CGDirectDisplayID, of source: CGDirectDisplayID,
                              option: CGConfigureOption = .permanently) throws {
        guard target != source else { throw DisplayError.invalidArgument("cannot mirror a display onto itself") }
        try configure("mirror", option: option) { CGConfigureDisplayMirrorOfDisplay($0, target, source) }
    }

    public static func unmirror(_ target: CGDirectDisplayID, option: CGConfigureOption = .permanently) throws {
        try configure("unmirror", option: option) { CGConfigureDisplayMirrorOfDisplay($0, target, kCGNullDirectDisplay) }
    }

    /// Software connect/disconnect. Lasts until logout by default (`.forSession`); never pass
    /// `.permanently` here. Refuses to disable the last active physical display.
    public static func setEnabled(_ enabled: Bool, for id: CGDirectDisplayID,
                                  option: CGConfigureOption = .forSession) throws {
        guard let configureEnabled = PrivateSymbols.cgsConfigureDisplayEnabled else {
            throw PrivateSymbols.missing("CGSConfigureDisplayEnabled")
        }
        if !enabled {
            let remaining = onlineDisplayIDs().filter {
                $0 != id && CGDisplayIsActive($0) != 0 && isPhysical($0)
            }
            guard !remaining.isEmpty else {
                throw DisplayError.refused("would disable the last active physical display")
            }
        }
        try configure(enabled ? "enable display" : "disable display", option: option) { config in
            CGError(rawValue: configureEnabled(config, id, enabled)) ?? .failure
        }
    }

    /// Built-in, or driven by a framebuffer (has an `IODisplayLocation`). Virtual, Sidecar,
    /// AirPlay and DisplayLink displays do not count.
    public static func isPhysical(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(id) != 0 || AVServiceDiscovery.displayLocation(id) != nil
    }

    static func configure(_ op: String, option: CGConfigureOption = .permanently,
                          _ body: (CGDisplayConfigRef) -> CGError) throws {
        var config: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&config), "\(op): begin")
        guard let config else { throw DisplayError.unavailable("\(op): no configuration") }
        let err = body(config)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.coreGraphics(err, op)
        }
        try check(CGCompleteDisplayConfiguration(config, option), "\(op): complete")
    }

    // MARK: Selection

    /// Resolves a CLI-style selector: list index (`0`), display ID (`id:69733248`),
    /// `main`, `builtin`, or a case-insensitive name substring.
    public static func resolve(_ selector: String) throws -> DisplayInfo {
        let all = displays()
        let s = selector.lowercased()
        if s == "main", let d = all.first(where: \.isMain) { return d }
        if s == "builtin", let d = all.first(where: \.isBuiltin) { return d }
        if s.hasPrefix("id:"), let id = UInt32(s.dropFirst(3)), let d = all.first(where: { $0.id == id }) { return d }
        if let n = Int(s) {
            let byIndex = all.indices.contains(n) ? all[n] : nil
            let byID = all.first { Int($0.id) == n }
            if let byIndex, let byID, byIndex.id != byID.id {
                throw DisplayError.invalidArgument(
                    "'\(selector)' is list index \(n) (\(byIndex.name)) and display ID \(n) (\(byID.name)); "
                        + "use id:\(n) for the ID or a name")
            }
            if let d = byIndex ?? byID { return d }
            throw DisplayError.displayNotFound(selector)
        }
        let matches = all.filter { $0.name.lowercased().contains(s) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw DisplayError.invalidArgument("'\(selector)' matches \(matches.count) displays") }
        throw DisplayError.displayNotFound(selector)
    }

    // MARK: Observation

    public final class ReconfigurationToken: @unchecked Sendable {
        fileprivate let handler: @Sendable () -> Void
        fileprivate init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
        deinit {
            CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Calls `handler` after each completed display reconfiguration. Keep the token alive.
    public static func observeReconfiguration(_ handler: @escaping @Sendable () -> Void) -> ReconfigurationToken {
        let token = ReconfigurationToken(handler)
        CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, Unmanaged.passUnretained(token).toOpaque())
        return token
    }
}

private func reconfigurationCallback(_: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                                     _ context: UnsafeMutableRawPointer?) {
    guard let context, !flags.contains(.beginConfigurationFlag) else { return }
    Unmanaged<DisplayManager.ReconfigurationToken>.fromOpaque(context).takeUnretainedValue().handler()
}

public struct ModeSpec: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var refreshRate: Double?
    public var hiDPI: Bool?

    /// Parses `WxH`, `WxH@Hz`, optionally followed by ` hidpi` / ` lodpi`.
    public init(_ text: String) throws {
        var parts = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard !parts.isEmpty else { throw DisplayError.invalidArgument("empty mode") }
        let head = parts.removeFirst()
        let invalid = DisplayError.invalidArgument("mode '\(text)' (expected WxH[@Hz] [hidpi|lodpi])")
        let sizeAndHz = head.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard sizeAndHz.count <= 2 else { throw invalid }
        let dims = sizeAndHz[0].split(separator: "x", omittingEmptySubsequences: false).map { Int($0) }
        guard dims.count == 2, let w = dims[0], let h = dims[1], w > 0, h > 0 else { throw invalid }
        width = w
        height = h
        if sizeAndHz.count == 2 {
            guard let hz = Double(sizeAndHz[1]), hz.isFinite, hz > 0 else {
                throw DisplayError.invalidArgument("refresh rate in '\(text)'")
            }
            refreshRate = hz
        }
        for flag in parts {
            switch flag {
            case "hidpi": hiDPI = true
            case "lodpi": hiDPI = false
            default: throw DisplayError.invalidArgument("unknown mode flag '\(flag)'")
            }
        }
    }
}

extension NSScreen {
    public var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
