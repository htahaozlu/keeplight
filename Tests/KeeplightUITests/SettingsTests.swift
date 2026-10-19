import AppKit
import Darwin
import DisplayCore
import Foundation
import Testing
@testable import KeeplightUI

@MainActor
@Suite("Settings tabs")
struct SettingsTabTests {
    @Test func tabsSwitchWithoutAnimation() {
        // A settings window is read, not watched: no cross-fade, no slide, at any Reduce Motion.
        #expect(SettingsTabViewController.transitions == [])
    }

    @Test func threeTabsInToolbarOrderWithSystemSymbols() {
        #expect(SettingsTab.allCases == [.general, .displays, .about])
        #expect(SettingsTab.allCases.map(\.title) == ["General", "Displays", "About"])
        #expect(SettingsTab.allCases.map(\.symbol) == ["gearshape", "display", "info.circle"])
        for tab in SettingsTab.allCases {
            #expect(NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil) != nil)
        }
        // The journal tab is gone; an old debug state name no longer opens anything.
        #expect(SettingsTab(rawValue: "journal") == nil)
    }

    @Test func tabControllerHasOneToolbarItemPerTabAndCommandDigitsSelectThem() {
        let rig = Rig()
        let tabs = SettingsTabViewController(model: rig.model)
        #expect(tabs.tabStyle == .toolbar)
        #expect(tabs.tabViewItems.map(\.label) == ["General", "Displays", "About"])
        #expect(tabs.tabViewItems.compactMap { $0.identifier as? String } == ["general", "displays", "about"])
        #expect(tabs.tabViewItems.allSatisfy { $0.image != nil })
        _ = tabs.view
        func command(_ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: 0)!
        }
        #expect(tabs.handleKeyEquivalent(command("3")))
        #expect(tabs.selectedTabViewItemIndex == 2)
        #expect(rig.model.settingsTab == .about)
        #expect(tabs.handleKeyEquivalent(command("2")))
        #expect(rig.model.settingsTab == .displays)
        #expect(!tabs.handleKeyEquivalent(command("4")))
        #expect(rig.model.settingsTab == .displays)
        tabs.select(.general)
        #expect(rig.model.settingsTab == .general)
    }

    @Test func everyTabIsTheWindowWidthAndAsTallAsItsContent() {
        let rig = Rig()
        for tab in SettingsTab.allCases {
            let size = SettingsWindowController.size(for: tab, model: rig.model)
            #expect(size.width == 560)
            #expect(size.height > 100 && size.height < 900, "\(tab): \(size.height)")
        }
        #expect(SettingsWindowController.size(for: .displays, model: rig.model).height >= DisplaysTab.minHeight)
    }

    @Test func generalGrowsForTheKeysRows() {
        let rig = Rig()
        let off = SettingsWindowController.size(for: .general, model: rig.model).height
        rig.model.prefs.brightnessKeys = true
        let waiting = SettingsWindowController.size(for: .general, model: rig.model).height
        rig.model.brightnessKeysActive = true
        let on = SettingsWindowController.size(for: .general, model: rig.model).height
        #expect(waiting > on)
        #expect(on > off)
    }
}

@Suite("Settings › Displays › Brightness")
struct BrightnessLineTests {
    private static func info(builtin: Bool = false) -> DisplayInfo {
        DisplayInfo(id: 7, name: "Test Display", vendorID: 1, productID: 2, serialNumber: 3, uuid: nil,
                    isBuiltin: builtin, isMain: true, isActive: true, isOnline: true, mirrorSource: nil,
                    bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), rotation: 0, currentMode: nil,
                    fingerprint: "TEST:1")
    }

    /// DisplayCore's memberwise init is internal: build the report through its Codable form.
    private struct Wire: Encodable {
        var display = "Test Display"
        var fingerprint = "TEST:1"
        var steps: [DiagnosticStep] = []
        var verdict = ""
        var facts: DiagnosticFacts
        var hardwareModel = "Mac15,6"
        var architecture = "arm64"
        var macOS = "15.1"
        var edid: String?
        var serial: String?
        var keeplightVersion = Keeplight.version
        var generatedAt = Date(timeIntervalSinceReferenceDate: 0)
    }

    private static func report(_ facts: DiagnosticFacts) -> DiagnosticReport {
        let data = try! JSONEncoder().encode(Wire(facts: facts))
        return try! JSONDecoder().decode(DiagnosticReport.self, from: data)
    }

    private static func facts(connection: DiagnosticFacts.Connection = .direct, intel: Bool = false,
                              channel: Bool? = true, reply: DiagnosticFacts.DDCReply) -> DiagnosticFacts {
        DiagnosticFacts(connection: connection, isIntel: intel, hardwareModel: "Mac15,6", appleBrightness: false,
                        ddcChannel: channel, ddcReply: reply)
    }

    private final class Control: BrightnessControl, @unchecked Sendable {
        let displayID: CGDirectDisplayID = 7
        let backend: BrightnessBackend
        init(_ backend: BrightnessBackend) { self.backend = backend }
        func brightness() throws -> Double { 0.5 }
        func setBrightness(_ value: Double) throws {}
    }

    @Test func mechanismWordWhenThereIsControl() {
        let ddc = BrightnessState.available(control: Control(.ddc), value: 0.4, readMs: 100)
        let apple = BrightnessState.available(control: Control(.apple), value: 0.7, readMs: 3)
        #expect(Copy.brightnessLine(ddc, report: nil, display: Self.info()) == "Over the cable")
        #expect(Copy.brightnessLine(apple, report: nil, display: Self.info(builtin: true)) == "By macOS")
    }

    @Test func checkingUntilProbeOrDiagnosisAnswers() {
        #expect(Copy.brightnessLine(nil, report: nil, display: Self.info()) == "Checking…")
        #expect(Copy.brightnessLine(.probing, report: nil, display: Self.info()) == "Checking…")
        #expect(Copy.brightnessLine(.unavailable, report: nil, display: Self.info()) == "Checking…")
    }

    @Test func noControlGivesTheOneReason() {
        let none = Self.report(Self.facts(reply: .noReply))
        #expect(Copy.brightnessLine(.unavailable, report: none, display: Self.info())
            == Copy.noControlLine(none, display: Self.info()))
        let locked = Self.report(Self.facts(reply: .maxZero))
        #expect(Copy.brightnessLine(.unavailable, report: locked, display: Self.info())
            == "This input or picture mode locks brightness.")
        let dock = Self.report(Self.facts(channel: false, reply: .noReply))
        #expect(Copy.brightnessLine(.unavailable, report: dock, display: Self.info()) == "This dock or cable blocks DDC.")
        let intel = Self.report(Self.facts(intel: true, reply: .noReply))
        #expect(Copy.brightnessLine(.unavailable, report: intel, display: Self.info()).hasPrefix("Intel Macs"))
    }
}

@Suite("About › Integrity probe")
struct IntegrityProbeTests {
    @Test func countsOnlyInternetSockets() {
        let descriptors: [IntegrityProbe.Descriptor] = [
            .file(), .socket(AF_UNIX), .socket(AF_INET), .socket(AF_INET6), .socket(nil), .socket(AF_SYSTEM), .file(),
        ]
        #expect(IntegrityProbe.ipSocketCount(in: descriptors) == 2)
        #expect(IntegrityProbe.ipSocketCount(in: []) == 0)
        #expect(IntegrityProbe.ipSocketCount(in: [.socket(AF_UNIX), .file()]) == 0)
        // A non-socket descriptor that happens to carry an INET family is not a socket.
        #expect(IntegrityProbe.ipSocketCount(in: [IntegrityProbe.Descriptor(type: 1, family: AF_INET)]) == 0)
    }

    @Test func readsThisProcess() throws {
        let descriptors = try #require(IntegrityProbe.descriptors(of: getpid()))
        // stdin/stdout/stderr at least; the pipe below adds two more.
        #expect(descriptors.count >= 3)
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let after = try #require(IntegrityProbe.descriptors(of: getpid()))
        // Other suites open and close descriptors in parallel, so count only kinds this test owns:
        // its two pipe ends are there while the pipe is open.
        #expect(after.filter { $0.type == UInt32(PROX_FDTYPE_PIPE) }.count >= 2)
        #expect(IntegrityProbe.ipSocketCount() != nil)
    }

    @Test func aProcessThatIsGoneIsUnreadable() {
        #expect(IntegrityProbe.descriptors(of: 999_999) == nil)
    }
}

@Suite("About › reading")
struct AboutReadingTests {
    /// DisplayCore's memberwise init is internal: decode the public Codable form.
    private static func interface(_ symbol: String, _ framework: String, _ purpose: String, found: Bool) -> PrivateInterface {
        let json: [String: Any] = ["symbol": symbol, "framework": framework, "purpose": purpose, "isResolved": found]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(PrivateInterface.self, from: data)
    }

    private static func reading(sockets: Int?, missing: Bool = false) -> AboutReading {
        AboutReading(sockets: sockets, accessibilityAllowed: false,
                     interfaces: [interface("CGSConfigureDisplayEnabled", "CoreGraphics", "disconnect a display", found: true),
                                  interface("DisplayServicesSetBrightness", "DisplayServices", "Apple display brightness",
                                            found: !missing)],
                     signature: "Ad-hoc — built from source", dataPath: "~/Library/Application Support/Keeplight",
                     measuredAt: Date(timeIntervalSince1970: 0))
    }

    @Test func faceValues() {
        #expect(Self.reading(sockets: 0).network == "0 connections")
        #expect(Self.reading(sockets: 1).network == "1 connection")
        #expect(Self.reading(sockets: nil).network == "—")
        #expect(Self.reading(sockets: 0).accessibility == "Not used")
        var allowed = Self.reading(sockets: 0)
        allowed.accessibilityAllowed = true
        #expect(allowed.accessibility == "Allowed")
        #expect(Self.reading(sockets: 0).privateAPIs == "2 of 2 found")
        #expect(Self.reading(sockets: 0, missing: true).privateAPIs == "1 of 2 found")
    }

    @Test func symbolLinesSayWhatIsMissing() {
        let rows = Self.reading(sockets: 0, missing: true).interfaces
        #expect(AboutReading.line(rows[0]) == "CGSConfigureDisplayEnabled — disconnect a display")
        #expect(AboutReading.line(rows[1]) == "DisplayServicesSetBrightness — Apple display brightness · missing")
    }

    @Test func reportCarriesTheFaceAndTheSymbols() {
        let report = Self.reading(sockets: 0, missing: true).report()
        #expect(report.hasPrefix("Keeplight \(Keeplight.version)"))
        #expect(report.contains("Network: 0 connections"))
        #expect(report.contains("Private APIs: 1 of 2 found"))
        #expect(report.contains("DisplayServicesSetBrightness — Apple display brightness · missing"))
        #expect(report.contains("License: MIT"))
    }

    @Test func homePathsAreAbbreviated() {
        let home = NSHomeDirectory()
        #expect(AboutReading.abbreviated(home + "/Library/Application Support/Keeplight")
            == "~/Library/Application Support/Keeplight")
        #expect(AboutReading.abbreviated("/private/tmp/x") == "/private/tmp/x")
    }

    @Test func versionIsDisplayCoresWithTheArchitecture() {
        #expect(Keeplight.version == "0.3.0")
        #expect(BuildInfo.versionLine == "0.3.0 · \(BuildInfo.architecture)")
    }
}
