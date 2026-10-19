import CoreGraphics
import DisplayCore
import Foundation

enum Commands {
    // MARK: Inventory

    static func list(_ args: Arguments) throws {
        try args.noMore(than: 0)
        let displays = DisplayManager.displays()
        if args.has("--json") { return try Output.json(displays) }
        Output.table(["#", "ID", "NAME", "MODE", "FLAGS"], displays.enumerated().map { i, d in
            [String(i), String(d.id), d.name, d.currentMode?.label ?? "-", flags(d)]
        }, right: [0, 1])
    }

    static func info(_ args: Arguments) throws {
        try args.noMore(than: 1)
        let d = try resolve(args.required(0, "display"))
        let index = DisplayManager.displays().firstIndex { $0.id == d.id }
        let edid = EDID.read(for: d)
        let ddc = DDCService(display: d) != nil
        let native = DisplayManager.nativePixelSize(for: d.id)
        let brightness = Brightness.control(for: d).map { control in
            do {
                return InfoRecord.BrightnessState(backend: control.backend,
                                                  percent: Format.percent(try control.brightness()), error: nil)
            } catch {
                return InfoRecord.BrightnessState(backend: control.backend, percent: nil, error: "\(error)")
            }
        }
        if args.has("--json") {
            return try Output.json(InfoRecord(index: index, display: d, brightness: brightness, ddc: ddc,
                                              edid: edid.map(EDIDRecord.init),
                                              nativePixels: native.map { "\($0.width)x\($0.height)" },
                                              sharpness: native.flatMap { n in d.currentMode?.sharpness(native: n) }))
        }
        Output.fields([
            ("Name", d.name),
            ("Index", index.map(String.init) ?? "-"),
            ("ID", String(d.id)),
            ("Fingerprint", d.fingerprint),
            ("UUID", d.uuid ?? "-"),
            ("Vendor", Format.hex(d.vendorID, digits: 4) + (Format.pnp(d.vendorID).map { " (\($0))" } ?? "")),
            ("Product", Format.hex(d.productID, digits: 4)),
            ("Serial", d.serialNumber == 0 ? "-" : String(d.serialNumber)),
            ("Built-in", Format.yesNo(d.isBuiltin)),
            ("Main", Format.yesNo(d.isMain)),
            ("Active", Format.yesNo(d.isActive)),
            ("Online", Format.yesNo(d.isOnline)),
            ("Mirror of", d.mirrorSource.map { "\(DisplayManager.name(for: $0)) (id \($0))" } ?? "-"),
            ("Bounds", Format.bounds(d.bounds)),
            ("Rotation", Format.number(d.rotation) + "°"),
            ("Mode", d.currentMode.map { mode in
                "\(mode.label) (#\(mode.modeNumber), \(mode.pixelWidth)x\(mode.pixelHeight) px"
                    + (native.map { ", \(mode.sharpness(native: $0).tag)" } ?? "") + ")"
            } ?? "-"),
            ("Native", native.map { "\($0.width)x\($0.height) px" } ?? "-"),
            ("Brightness", brightness.map { b in
                b.percent.map { "\($0)% (\(b.backend.rawValue))" } ?? "\(b.backend.rawValue): \(b.error ?? "unreadable")"
            } ?? "-"),
            ("DDC", Format.yesNo(ddc)),
            ("EDID", edid.map(edidSummary) ?? "-"),
        ])
    }

    static func modes(_ args: Arguments) throws {
        try args.noMore(than: 1)
        let d = try resolve(args.required(0, "display"))
        let all = DisplayManager.modes(for: d.id)
        let current = DisplayManager.currentMode(for: d.id)
        let native = DisplayManager.nativePixelSize(for: d.id)
        let json = args.has("--json")
        func record(_ m: DisplayMode) -> ModeRecord {
            ModeRecord(m, current: m.modeNumber == current?.modeNumber, sharpness: native.map { m.sharpness(native: $0) })
        }
        if args.has("--all") {
            let records = all.map(record)
            if json { return try Output.json(records) }
            Output.table(["", "#", "SIZE", "HZ", "DEPTH", "DENSITY", "FLAGS", "PIXELS"], records.map { m in
                [m.current ? "*" : "", String(m.modeNumber), "\(m.width)x\(m.height)", Format.number(m.refreshRate),
                 String(m.depth), String(format: "%.1f", m.density), Format.hex(m.flags, digits: 8),
                 "\(m.pixelWidth)x\(m.pixelHeight)"]
            }, right: [1, 3, 4, 5])
        } else {
            let records = DisplayManager.uniqueModes(all, current: current).map(record)
            if json { return try Output.json(records) }
            Output.table(["", "#", "MODE", "PIXELS", "TAG"], records.map { m in
                [m.current ? "*" : "", String(m.modeNumber), m.label, "\(m.pixelWidth)x\(m.pixelHeight)",
                 m.sharpness?.tag ?? "-"]
            }, right: [1])
        }
    }

    static func edid(_ args: Arguments) throws {
        try args.noMore(than: 1)
        if args.has("--raw"), args.has("--json") { throw UsageError("--raw and --json are mutually exclusive") }
        let d = try resolve(args.required(0, "display"))
        guard let edid = EDID.read(for: d) else { throw DisplayError.unavailable("no EDID for \(d.tag)") }
        if args.has("--raw") { return Output.hexDump(edid.raw).forEach { print($0) } }
        if args.has("--json") { return try Output.json(EDIDRecord(edid)) }
        Output.fields([
            ("Manufacturer", edid.manufacturerID),
            ("Product code", Format.hex(edid.productCode, digits: 4)),
            ("Serial number", edid.serialNumber == 0 ? "-" : String(edid.serialNumber)),
            ("Serial string", edid.serialString ?? "-"),
            ("Name", edid.displayName ?? "-"),
            ("Manufactured", Format.manufactured(edid)),
            ("Version", "\(edid.version).\(edid.revision)"),
            ("Screen size", edid.widthCM > 0 && edid.heightCM > 0 ? "\(edid.widthCM) x \(edid.heightCM) cm" : "-"),
            ("Preferred mode", edid.preferredTiming.map {
                Format.timing($0) + ", pixel clock " + Format.number(Double($0.pixelClockKHz) / 1000) + " MHz"
            } ?? "-"),
            ("Extensions", String(edid.extensionCount)),
            ("Checksum", edid.checksumValid ? "valid" : "INVALID"),
            ("Bytes", String(edid.raw.count)),
        ])
    }

    // MARK: Configuration
    //
    // Applied directly with their permanent/session option (no transaction: this process exits
    // at once, and `.forAppOnly` would drop the change) and journaled with source `cli`.

    private static let direct = DirectChange(applier: LiveDisplaySystem())

    static func mode(_ args: Arguments) throws {
        let selector = try args.required(0, "display")
        if let raw = args.value("--number") {
            try args.noMore(than: 1)
            guard let number = Int32(raw) else { throw UsageError("invalid mode number '\(raw)'") }
            let d = try resolve(selector)
            guard let mode = DisplayManager.modes(for: d.id).first(where: { $0.modeNumber == number }) else {
                throw DisplayError.modeNotFound("#\(number) on \(d.tag)")
            }
            guard mode.isUsable || args.has("--force") else {
                throw DisplayError.refused("mode #\(number) lacks the valid flag; pass --force to apply it anyway")
            }
            try journaled(.mode, d.ref) { try DisplayManager.setMode(number, for: d.id) }
            print("\(d.tag): mode set to \(mode.label) (#\(number))")
            return
        }
        try args.noMore(than: 3)
        var spec = try args.required(1, "WxH[@Hz]")
        if let density = args.optional(2) {
            guard ["hidpi", "lodpi"].contains(density.lowercased()) else {
                throw UsageError("expected hidpi or lodpi, got '\(density)'")
            }
            spec += " " + density
        }
        do { _ = try ModeSpec(spec) } catch { throw UsageError("\(error)") }
        let d = try resolve(selector)
        let mode = try DisplayManager.findMode(spec, for: d.id)
        try journaled(.mode, d.ref) { try DisplayManager.setMode(mode.modeNumber, for: d.id) }
        print("\(d.tag): mode set to \(mode.label) (#\(mode.modeNumber))")
    }

    static func main(_ args: Arguments) throws {
        try args.noMore(than: 1)
        let d = try resolve(args.required(0, "display"))
        try journaled(.main, d.ref) { try DisplayManager.setMain(d.id) }
        print("\(d.tag) is now the main display")
    }

    static func mirror(_ args: Arguments) throws {
        try args.noMore(than: 2)
        let targetSelector = try args.required(0, "target")
        let sourceSelector = try args.required(1, "source")
        let target = try resolve(targetSelector)
        let source = try resolve(sourceSelector)
        try journaled(.mirror, target.ref) { try DisplayManager.mirror(target.id, of: source.id) }
        print("\(target.tag) now mirrors \(source.tag)")
    }

    static func unmirror(_ args: Arguments) throws {
        try args.noMore(than: 1)
        let d = try resolve(args.required(0, "target"))
        guard d.isMirrorTarget else { return print("\(d.tag) was not mirroring another display") }
        try journaled(.unmirror, d.ref) { try DisplayManager.unmirror(d.id) }
        print("\(d.tag) no longer mirrors")
    }

    static func enable(_ args: Arguments) throws {
        try args.noMore(than: 1)
        let (id, ref) = try enableTarget(args.required(0, "display"))
        if CGDisplayIsOnline(id) != 0, CGDisplayIsActive(id) != 0 {
            throw DisplayError.refused("display \(id) is already enabled")
        }
        try journaled(.reconnect, ref, displayID: id) { try DisplayManager.setEnabled(true, for: id) }
        try? DisconnectedRegistry.standard.remove { $0.displayID == id }
        print("display \(id) enabled")
    }

    static func disable(_ args: Arguments) throws {
        try args.noMore(than: 1)
        let d = try resolve(args.required(0, "display"))
        try journaled(.disconnect, d.ref, displayID: d.id) { try DisplayManager.setEnabled(false, for: d.id) }
        print("\(d.tag) disabled until logout; re-enable with: keeplight enable \(d.id)")
    }

    // MARK: Brightness and DDC

    static func brightness(_ args: Arguments) throws {
        try args.noMore(than: 2)
        let selector = try args.required(0, "display")
        let backend = try args.value("--backend").map { raw in
            guard let b = BrightnessBackend(rawValue: raw.lowercased()) else {
                throw UsageError("unknown backend '\(raw)' (expected apple or ddc)")
            }
            return b
        }
        let target = try args.optional(1).map { raw in
            guard let v = Double(raw.hasSuffix("%") ? String(raw.dropLast()) : raw), (0...100).contains(v) else {
                throw UsageError("brightness must be 0-100, got '\(raw)'")
            }
            return v
        }
        let d = try resolve(selector)
        let control: any BrightnessControl
        if let backend {
            guard let c = Brightness.make(backend, for: d) else {
                throw DisplayError.unavailable("\(backend.rawValue) brightness on \(d.tag)")
            }
            control = c
        } else {
            guard let c = Brightness.control(for: d) else {
                throw DisplayError.unavailable("no brightness control for \(d.tag)")
            }
            control = c
        }
        if let target {
            let before = (try? control.brightness()).map { "\(Format.percent($0))%" }
            let outcome = try direct.record(.brightness, display: d.ref, before: before,
                                            after: "\(Format.number(target))%", mechanism: control.backend.mechanism) {
                try control.setBrightness(target / 100)
            }
            warnIfUnjournaled(outcome)
            print("\(d.tag): brightness set to \(Format.number(target))% (\(control.backend.rawValue))")
        } else {
            print("\(Format.percent(try control.brightness()))% (\(control.backend.rawValue))")
        }
    }

    static func ddc(_ args: Arguments) throws {
        let selector = try args.required(0, "display")
        let action = try args.required(1, "get|set").lowercased()
        guard action == "get" || action == "set" else {
            throw UsageError("unknown ddc action '\(action)' (expected get or set)")
        }
        let name = try args.required(2, "vcp")
        guard let vcp = VCP(name: name) else { throw UsageError("unknown VCP code '\(name)'") }
        var value: UInt16?
        if action == "set" {
            let raw = try args.required(3, "value")
            let t = raw.lowercased()
            guard let v = t.hasPrefix("0x") ? UInt16(t.dropFirst(2), radix: 16) : UInt16(t) else {
                throw UsageError("value must be 0-65535, got '\(raw)'")
            }
            value = v
        }
        try args.noMore(than: action == "set" ? 4 : 3)
        let d = try resolve(selector)
        guard let service = DDCService(display: d) else { throw DisplayError.unavailable("no DDC channel for \(d.tag)") }
        if let value {
            let outcome = try direct.record(.ddc, display: d.ref, before: nil, after: "\(vcpLabel(vcp)) = \(value)",
                                            mechanism: "DDC VCP " + Format.hex(vcp.rawValue, digits: 2)) {
                try service.write(vcp, value: value)
            }
            warnIfUnjournaled(outcome)
            print("\(d.tag): \(vcpLabel(vcp)) set to \(value)")
        } else {
            let reply = try service.read(vcp)
            print("\(vcpLabel(vcp)): \(reply.current) (max \(reply.maximum))")
        }
    }

    // MARK: Helpers

    private static func journaled(_ kind: JournalEntry.Kind, _ display: DisplayRef, displayID: CGDirectDisplayID? = nil,
                                  _ body: () throws -> Void) throws {
        warnIfUnjournaled(try direct.apply(kind, display: display, displayID: displayID, body: body))
    }

    private static func warnIfUnjournaled(_ outcome: DirectChange.Outcome) {
        if let error = outcome.journalError {
            Output.error("keeplight: warning: change applied but not journaled: \(error)")
        }
    }

    private static func flags(_ d: DisplayInfo) -> String {
        var flags: [String] = []
        if d.isMain { flags.append("main") }
        if d.isBuiltin { flags.append("builtin") }
        if let source = d.mirrorSource { flags.append("mirror of \(source)") }
        if !d.isActive { flags.append("inactive") }
        return flags.isEmpty ? "-" : flags.joined(separator: ", ")
    }

    static func resolve(_ selector: String) throws -> DisplayInfo {
        try DisplayManager.resolve(selector)
    }

    /// Numeric selectors name a display ID directly (never a list index), since a
    /// disconnected display is absent from the online list. Names and fingerprints are also
    /// looked up among displays Keeplight disconnected.
    private static func enableTarget(_ selector: String) throws -> (CGDirectDisplayID, DisplayRef) {
        let remembered = DisconnectedRegistry.standard.load()
        if let id = numericSelector(selector) {
            if let entry = remembered.first(where: { $0.displayID == id }) { return (id, entry.ref) }
            let info = DisplayManager.info(for: id)
            return (id, info.ref)
        }
        let s = selector.lowercased()
        let matches = remembered.filter { $0.fingerprint.lowercased() == s || $0.name.lowercased().contains(s) }
        if matches.count == 1 { return (matches[0].displayID, matches[0].ref) }
        if matches.count > 1 {
            throw DisplayError.invalidArgument("'\(selector)' matches \(matches.count) disconnected displays")
        }
        let d = try resolve(selector)
        return (d.id, d.ref)
    }

    /// `N` or `id:N`.
    private static func numericSelector(_ selector: String) -> UInt32? {
        let s = selector.lowercased()
        return UInt32(s.hasPrefix("id:") ? String(s.dropFirst(3)) : s)
    }

    private static func edidSummary(_ e: EDID) -> String {
        var parts = ["\(e.manufacturerID) \(Format.hex(e.productCode, digits: 4))"]
        if let name = e.displayName { parts.append("\"\(name)\"") }
        parts.append("v\(e.version).\(e.revision)")
        parts.append(Format.manufactured(e))
        if e.widthCM > 0, e.heightCM > 0 { parts.append("\(e.widthCM)x\(e.heightCM) cm") }
        if let t = e.preferredTiming { parts.append("preferred \(Format.timing(t))") }
        return parts.joined(separator: ", ")
    }

    private static func vcpLabel(_ vcp: VCP) -> String {
        let code = Format.hex(vcp.rawValue, digits: 2)
        return vcp.description == code ? "VCP \(code)" : "\(vcp.description) (VCP \(code))"
    }
}
