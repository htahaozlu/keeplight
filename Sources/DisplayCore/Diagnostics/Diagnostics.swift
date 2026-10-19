import CoreGraphics
import Darwin
import Foundation

/// How strongly a diagnostic step's evidence supports its result.
public enum DiagnosticGrade: String, Codable, Sendable {
    case observed
    case noReply = "no-reply"
    case notAvailable = "not-available"
    case notTested = "not-tested"

    /// `OBSERVED`, `NO REPLY`, `NOT AVAILABLE`, `NOT TESTED`.
    public var label: String { rawValue.replacingOccurrences(of: "-", with: " ").uppercased() }
}

public struct DiagnosticStep: Codable, Hashable, Sendable {
    public var name: String
    public var grade: DiagnosticGrade
    public var detail: String
    public var ms: Int?

    public init(name: String, grade: DiagnosticGrade, detail: String, ms: Int? = nil) {
        self.name = name
        self.grade = grade
        self.detail = detail
        self.ms = ms
    }
}

/// The evidence the verdict is chosen from.
public struct DiagnosticFacts: Codable, Hashable, Sendable {
    public enum Connection: String, Codable, Sendable {
        case builtin
        /// Driven by a framebuffer (has an `IODisplayLocation`).
        case direct
        /// USB graphics (DisplayLink), AirPlay, Sidecar or another virtual display.
        case virtual
    }

    public enum DDCReply: Hashable, Codable, Sendable {
        case notTested
        /// Brightness readable with this maximum.
        case max(UInt16)
        /// No valid reply after every retry.
        case noReply
        /// The monitor answered but does not expose brightness (max 0 or unsupported VCP).
        case maxZero
    }

    public var connection: Connection
    public var isIntel: Bool
    public var hardwareModel: String
    public var appleBrightness: Bool
    public var ddcChannel: Bool?
    public var ddcReply: DDCReply

    public init(connection: Connection, isIntel: Bool, hardwareModel: String, appleBrightness: Bool,
                ddcChannel: Bool?, ddcReply: DDCReply) {
        self.connection = connection
        self.isIntel = isIntel
        self.hardwareModel = hardwareModel
        self.appleBrightness = appleBrightness
        self.ddcChannel = ddcChannel
        self.ddcReply = ddcReply
    }
}

/// "Why can't I control this monitor?" [O§7.4]
public struct DiagnosticReport: Codable, Hashable, Sendable {
    public var display: String
    /// Fingerprint with its serial part redacted to the last 3 characters.
    public var fingerprint: String
    public var steps: [DiagnosticStep]
    public var verdict: String
    public var facts: DiagnosticFacts
    public var hardwareModel: String
    public var architecture: String
    public var macOS: String
    /// EDID `vendor product`, e.g. `DEL 0xA0F3`.
    public var edid: String?
    /// Serial redacted to its last 3 characters.
    public var serial: String?
    public var keeplightVersion: String
    public var generatedAt: Date

    /// Markdown for a GitHub issue: verdict, steps, Mac, macOS build, EDID vendor/product,
    /// redacted serial and the Keeplight version. Nothing is sent anywhere.
    public func markdownReport() -> String {
        var lines = [
            "### Keeplight diagnosis: \(display)",
            "",
            "**\(verdict)**",
            "",
            "| Step | Result | Detail | ms |",
            "|---|---|---|---|",
        ]
        for step in steps {
            let detail = step.detail.replacingOccurrences(of: "|", with: "\\|")
            lines.append("| \(step.name) | \(step.grade.label) | \(detail) | \(step.ms.map(String.init) ?? "–") |")
        }
        lines += [
            "",
            "- Mac: `\(hardwareModel)` (\(architecture))",
            "- macOS: \(macOS)",
            "- Display: \(edid ?? "EDID unavailable") · serial \(serial ?? "–") · fingerprint `\(fingerprint)`",
            "- Keeplight: \(keeplightVersion)",
        ]
        return lines.joined(separator: "\n")
    }
}

public enum Diagnostics {
    /// Mac models whose built-in HDMI port gives apps no DDC channel (M1 / M2 Mac mini,
    /// Mac Studio M1).
    public static let hdmiWithoutDDC: Set<String> = ["Macmini9,1", "Mac14,3", "Mac14,12", "Mac13,1", "Mac13,2"]

    /// Probes `display` step by step (Connection, Mac, Apple brightness, DDC channel, DDC reply,
    /// EDID). Read-only, but DDC probing can take ~300 ms; call off the main thread.
    public static func diagnose(_ display: DisplayInfo) -> DiagnosticReport {
        var steps: [DiagnosticStep] = []
        let model = hardwareModel()
        let intel = !isAppleSilicon()

        // 1. Connection
        var start = ContinuousClock.now
        let connection: DiagnosticFacts.Connection
        if display.isBuiltin {
            connection = .builtin
        } else if AVServiceDiscovery.displayLocation(display.id) != nil {
            connection = .direct
        } else {
            connection = .virtual
        }
        steps.append(DiagnosticStep(name: "Connection", grade: .observed, detail: [
            DiagnosticFacts.Connection.builtin: "Built-in",
            .direct: "Direct (framebuffer)",
            .virtual: "Virtual, USB, AirPlay or Sidecar",
        ][connection]!, ms: TransactionEngine.ms(since: start)))

        // 2. Mac
        steps.append(DiagnosticStep(name: "Mac", grade: .observed,
                                    detail: "\(model) · \(intel ? "Intel" : "Apple silicon")"))

        // 3. Apple brightness
        start = ContinuousClock.now
        var apple = false
        if let can = PrivateSymbols.displayServicesCanChangeBrightness {
            apple = can(display.id)
            var detail = "—"
            if apple, let control = AppleBrightness(displayID: display.id), let value = try? control.brightness() {
                detail = "DisplayServices · level \(Int((value * 100).rounded()))%"
            } else if apple {
                detail = "DisplayServices"
            }
            steps.append(DiagnosticStep(name: "Apple brightness", grade: apple ? .observed : .notAvailable,
                                        detail: detail, ms: TransactionEngine.ms(since: start)))
        } else {
            steps.append(DiagnosticStep(name: "Apple brightness", grade: .notAvailable,
                                        detail: "DisplayServicesCanChangeBrightness is missing"))
        }

        // 4–5. DDC channel and reply
        var channel: Bool?
        var reply = DiagnosticFacts.DDCReply.notTested
        if display.isBuiltin {
            steps.append(DiagnosticStep(name: "DDC channel", grade: .notTested, detail: "Built-in panels have no DDC/CI"))
            steps.append(DiagnosticStep(name: "DDC reply", grade: .notTested, detail: "—"))
        } else if intel {
            steps.append(DiagnosticStep(name: "DDC channel", grade: .notTested,
                                        detail: "DDC isn't implemented in Keeplight yet on Intel"))
            steps.append(DiagnosticStep(name: "DDC reply", grade: .notTested, detail: "—"))
        } else {
            start = ContinuousClock.now
            let service = DDCService(display: display)
            channel = service != nil
            steps.append(DiagnosticStep(name: "DDC channel", grade: service != nil ? .observed : .notAvailable,
                                        detail: service != nil ? "IOAVService found" : "No IOAVService for this display",
                                        ms: TransactionEngine.ms(since: start)))
            if let service {
                start = ContinuousClock.now
                do {
                    let r = try service.read(.brightness)
                    let ms = TransactionEngine.ms(since: start)
                    if r.maximum > 0 {
                        reply = .max(r.maximum)
                        steps.append(DiagnosticStep(name: "DDC reply", grade: .observed,
                                                    detail: "max \(r.maximum) · current \(r.current)", ms: ms))
                    } else {
                        reply = .maxZero
                        steps.append(DiagnosticStep(name: "DDC reply", grade: .notAvailable,
                                                    detail: "replied with max 0", ms: ms))
                    }
                } catch let DisplayError.ddc(message) where message.hasPrefix("unsupported") {
                    reply = .maxZero
                    steps.append(DiagnosticStep(name: "DDC reply", grade: .notAvailable,
                                                detail: "replied: brightness (VCP 0x10) unsupported",
                                                ms: TransactionEngine.ms(since: start)))
                } catch {
                    reply = .noReply
                    steps.append(DiagnosticStep(name: "DDC reply", grade: .noReply,
                                                detail: "no reply after 4 tries", ms: TransactionEngine.ms(since: start)))
                }
            } else {
                steps.append(DiagnosticStep(name: "DDC reply", grade: .notTested, detail: "No channel to ask"))
            }
        }

        // 6. EDID
        start = ContinuousClock.now
        let edid = EDID.read(for: display)
        if let edid {
            steps.append(DiagnosticStep(name: "EDID", grade: .observed,
                                        detail: "\(edid.version).\(edid.revision), checksum \(edid.checksumValid ? "ok" : "BAD")",
                                        ms: TransactionEngine.ms(since: start)))
        } else {
            steps.append(DiagnosticStep(name: "EDID", grade: .notAvailable, detail: "Not readable",
                                        ms: TransactionEngine.ms(since: start)))
        }

        let facts = DiagnosticFacts(connection: connection, isIntel: intel, hardwareModel: model,
                                    appleBrightness: apple, ddcChannel: channel, ddcReply: reply)
        let serial = edid?.serialString.flatMap { $0.isEmpty ? nil : $0 }
            ?? (display.serialNumber != 0 ? String(display.serialNumber) : nil)
        return DiagnosticReport(
            display: display.name, fingerprint: redactFingerprint(display.fingerprint), steps: steps,
            verdict: verdict(for: facts), facts: facts, hardwareModel: model, architecture: architecture(),
            macOS: macOSVersion(),
            edid: edid.map { "\($0.manufacturerID) 0x" + String(format: "%04X", $0.productCode) },
            serial: serial.map(redact), keeplightVersion: Keeplight.version, generatedAt: Date())
    }

    /// The one-sentence verdict [O§7.4] (exact copy), chosen by rule. Working brightness wins
    /// over every explanation of why another path fails.
    public static func verdict(for facts: DiagnosticFacts) -> String {
        if facts.appleBrightness { return "Brightness works through Apple DisplayServices." }
        if case .max(let m) = facts.ddcReply, m > 0 { return "Brightness works through DDC/CI." }
        if facts.connection == .virtual {
            return "This display is driven over USB graphics, AirPlay or Sidecar. There's no hardware path to its backlight, and Keeplight won't fake one with an overlay."
        }
        if facts.isIntel {
            return "On Intel Macs, Keeplight can't talk DDC/CI yet. Resolution and arrangement still work."
        }
        if facts.ddcChannel == false, hdmiWithoutDDC.contains(facts.hardwareModel) {
            return "Your Mac's built-in HDMI port gives apps no DDC channel. A USB-C or Thunderbolt to DisplayPort cable usually works."
        }
        switch facts.ddcReply {
        case .noReply:
            return "The monitor didn't answer DDC/CI. Many monitors ship with DDC/CI turned off — look for “DDC/CI” in the monitor's own menu, turn it on, then press Check Again."
        case .maxZero:
            return "The monitor answers DDC/CI but doesn't expose brightness on this input. Some HDR or eco modes lock it."
        default:
            break
        }
        if facts.connection == .builtin {
            return "macOS doesn't offer brightness control for this built-in display to apps."
        }
        return "macOS gives apps no DDC/CI channel to this display, so Keeplight can't reach its brightness. Another cable or port may work."
    }

    /// `…` plus the last 3 characters.
    public static func redact(_ serial: String) -> String {
        "…" + serial.suffix(3)
    }

    /// Redacts the serial part of `vendor:product:serial[:hash]`; UUID fingerprints are kept.
    public static func redactFingerprint(_ fp: String) -> String {
        var parts = fp.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0].count == 3 || parts[0].hasPrefix("0x") else { return fp }
        parts[2] = redact(parts[2])
        return parts.joined(separator: ":")
    }

    // MARK: System facts

    public static func hardwareModel() -> String { sysctlString("hw.model") ?? "unknown" }

    public static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static func architecture() -> String {
        #if arch(arm64)
        "arm64"
        #else
        isAppleSilicon() ? "x86_64 (Rosetta)" : "x86_64"
        #endif
    }

    static func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = sysctlString("kern.osversion").map { " (\($0))" } ?? ""
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "") + build
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
