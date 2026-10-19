import Foundation
import Testing
@testable import DisplayCore

private func facts(_ connection: DiagnosticFacts.Connection = .direct, intel: Bool = false, model: String = "Mac15,3",
                   apple: Bool = false, channel: Bool? = true,
                   reply: DiagnosticFacts.DDCReply = .notTested) -> DiagnosticFacts {
    DiagnosticFacts(connection: connection, isIntel: intel, hardwareModel: model, appleBrightness: apple,
                    ddcChannel: channel, ddcReply: reply)
}

@Test func verdictSelection() {
    #expect(Diagnostics.verdict(for: facts(.builtin, apple: true, channel: nil))
            == "Brightness works through Apple DisplayServices.")
    #expect(Diagnostics.verdict(for: facts(reply: .max(100))) == "Brightness works through DDC/CI.")
    #expect(Diagnostics.verdict(for: facts(.virtual, channel: false)).hasPrefix(
        "This display is driven over USB graphics, AirPlay or Sidecar. There's no hardware path to its backlight, and Keeplight won't fake one with an overlay."))
    #expect(Diagnostics.verdict(for: facts(intel: true, model: "MacBookPro16,1", channel: nil))
            == "On Intel Macs, Keeplight can't talk DDC/CI yet. Resolution and arrangement still work.")
    #expect(Diagnostics.verdict(for: facts(model: "Macmini9,1", channel: false))
            == "Your Mac's built-in HDMI port gives apps no DDC channel. A USB-C or Thunderbolt to DisplayPort cable usually works.")
    #expect(Diagnostics.verdict(for: facts(reply: .noReply))
            == "The monitor didn't answer DDC/CI. Many monitors ship with DDC/CI turned off — look for “DDC/CI” in the monitor's own menu, turn it on, then press Check Again.")
    #expect(Diagnostics.verdict(for: facts(reply: .maxZero))
            == "The monitor answers DDC/CI but doesn't expose brightness on this input. Some HDR or eco modes lock it.")
    // Working brightness beats an explanation of another path's failure.
    #expect(Diagnostics.verdict(for: facts(.virtual, apple: true)) == "Brightness works through Apple DisplayServices.")
    // An HDMI-limited model with a working channel is not blamed on HDMI.
    #expect(Diagnostics.verdict(for: facts(model: "Macmini9,1", reply: .noReply)).hasPrefix("The monitor didn't answer"))
    // No rule matches: a plain fallback, never empty.
    #expect(!Diagnostics.verdict(for: facts(model: "Mac15,3", channel: false)).isEmpty)
}

@Test func reportRedactsSerials() {
    #expect(Diagnostics.redact("4C3V2K3") == "…2K3")
    #expect(Diagnostics.redactFingerprint("DEL:A0F3:4C3V2K3") == "DEL:A0F3:…2K3")
    #expect(Diagnostics.redactFingerprint("DEL:A0F3:0:1a2b3c") == "DEL:A0F3:…0:1a2b3c")
    #expect(Diagnostics.redactFingerprint("AF2FA15D-2729-4BDB-BFFC-177C553D8F55") == "AF2FA15D-2729-4BDB-BFFC-177C553D8F55")

    let report = DiagnosticReport(
        display: "DELL U2723QE", fingerprint: Diagnostics.redactFingerprint("DEL:A0F3:4C3V2K3"),
        steps: [DiagnosticStep(name: "Connection", grade: .observed, detail: "Direct (framebuffer)", ms: 1),
                DiagnosticStep(name: "DDC reply", grade: .noReply, detail: "no reply after 4 tries", ms: 301)],
        verdict: Diagnostics.verdict(for: facts(reply: .noReply)), facts: facts(reply: .noReply),
        hardwareModel: "Mac15,3", architecture: "arm64", macOS: "26.5 (25F71)", edid: "DEL 0xA0F3",
        serial: Diagnostics.redact("4C3V2K3"), keeplightVersion: Keeplight.version, generatedAt: Date())
    let md = report.markdownReport()
    #expect(md.contains("| DDC reply | NO REPLY | no reply after 4 tries | 301 |"))
    #expect(md.contains("`Mac15,3`") && md.contains("26.5 (25F71)") && md.contains("DEL 0xA0F3"))
    #expect(md.contains("…2K3") && !md.contains("4C3V2K3"))
    #expect(md.contains(Keeplight.version))
    #expect(DiagnosticGrade.notAvailable.label == "NOT AVAILABLE")
}
