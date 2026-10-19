#if DEBUG
import AppKit
import DisplayCore
import SwiftUI
@testable import KeeplightUI

/// One surface in one state. `render` builds a fresh model per appearance.
struct Scenario {
    let name: String
    let surface: String
    let state: String
    /// Opts out of the contrast gate: a dimmed panel (disabled controls are exempt from WCAG
    /// contrast), a pressed state (held only under the mouse) and the material stand-in (its
    /// colour is a guess; the Reduce Transparency renders are the exact, gated form).
    var dimmed = false
    /// Light and dark; Increase Contrast scenarios render its two variants instead.
    var looks: [Look] = Look.standard
    let render: @MainActor (Look) -> Capture

    /// Text on the panel and in Settings must reach 4.5:1 against its background. Overlays are
    /// always-dark instrument cards with their own tokens.
    var checksContrast: Bool { (surface == "Panel" || surface == "Settings" || surface == "Onboarding") && !dimmed }
}

@MainActor
enum Scenarios {
    static func all() -> [Scenario] { panel() + [whyPopover()] + keep() + identify() + fuse() + osd() + rescue() + glyph() + settings() + onboarding() }

    // MARK: Panel

    private static func panelScenario(_ name: String, _ state: String, desk: Desk.Kind = .three,
                                      disconnected: [DisconnectedDisplay] = [], dimmed: Bool = false,
                                      looks: [Look] = Look.standard, frame: Frame = .panel,
                                      controlState: ControlState? = nil,
                                      _ configure: @escaping @MainActor (AppModel) -> Void = { _ in }) -> Scenario {
        Scenario(name: "panel-\(name)", surface: "Panel", state: state, dimmed: dimmed, looks: looks) { look in
            let model = Models.make(desk, disconnected: disconnected)
            configure(model)
            // `PanelController.clampedHeight`: the content's natural height within 80…max.
            return Renderer.render(PanelRoot().environment(model), look: look, frame: frame, width: Metrics.panelWidth,
                                   measure: { min(max(model.panelContentHeight, 80), model.panelMaxHeight) },
                                   settle: 1.0, controlState: controlState)
        }
    }

    /// The DELL's level, unknown (read failed) or still being read.
    static func dellBrightness(_ model: AppModel, _ state: BrightnessState) {
        model.brightness[dell(model).id] = state
        model.prefs.lastWritten[dell(model).fingerprint] = nil
    }

    static var benq: (AppModel) -> DisplayItem { { $0.items[0] } }

    /// `elapsed`: how long the render takes until capture (panel 1.3 s, overlays 1.05 s), so the
    /// countdown reads `secondsLeft` in the PNG.
    static func pendingMode(_ model: AppModel, secondsLeft: Double, total: Double = 15, elapsed: Double = 1.3,
                            display: DisplayItem? = nil) -> PendingInfo {
        let dell = display ?? model.items.first { $0.fingerprint.hasSuffix("DELL") }!
        let target = dell.recommended.first { $0.width == 3008 } ?? dell.recommended.last!
        let now = Date()
        let deadline = now.addingTimeInterval(elapsed + secondsLeft - 0.3)
        let name = model.name(dell.info)
        return PendingInfo(id: "render-pending", kind: .mode, displayName: name, title: OverlayCopy.keepTitle(.mode, name: name, summary: "\(dell.current?.sizeText ?? "?") → \(target.sizeText)"),
                           detail: "\(name) · \(dell.current?.sizeText ?? "?") → \(target.sizeText)",
                           displayFingerprint: dell.fingerprint, before: dell.current?.label ?? "",
                           startedAt: deadline.addingTimeInterval(-total), deadline: deadline)
    }

    static func lg(_ model: AppModel) -> DisplayItem { model.items.first { $0.fingerprint.hasSuffix(":LG") }! }
    static func dell(_ model: AppModel) -> DisplayItem { model.items.first { $0.fingerprint.hasSuffix("DELL") }! }

    static func undo(_ model: AppModel) {
        let entry = JournalEntry(id: "render-undo", source: .panel, display: dell(model).info.ref, kind: .brightness,
                                 before: "55%", after: "40%", mechanism: "DDC VCP 0x10", result: .applied)
        model.undoCandidate = UndoCandidate(entry: entry, label: "Undo " + Copy.change(entry) + " on DELL U2723QE")
    }

    static func panel() -> [Scenario] {
        [
            panelScenario("1-display", "The owner's desk: clamshell, one external 4K monitor (DDC), nothing pending",
                          desk: .clamshell),
            panelScenario("1-display-material", "As 1-display, on a stand-in for the menu material (tiles translucent)",
                          desk: .clamshell, dimmed: true, frame: .panelOnMaterial),
            panelScenario("1-display-ic", "As 1-display, Increase Contrast", desk: .clamshell,
                          looks: Look.increasedContrast),
            panelScenario("1-display-hover", "As 1-display, every control under the pointer (percent primary, washes up)",
                          desk: .clamshell, controlState: .hover),
            panelScenario("1-display-pressed", "As 1-display, every control pressed (drag live, chips pressed, ink α.6)",
                          desk: .clamshell, dimmed: true, controlState: .pressed),
            panelScenario("1-display-low", "Clamshell desk at 0: the fill never shrinks below the glyph",
                          desk: .clamshell) {
                $0.brightness[benq($0).id] = .available(
                    control: FakeBrightness(displayID: benq($0).id, backend: .ddc, level: 0), value: 0, readMs: 112)
            },
            panelScenario("1-builtin", "One built-in display (Apple brightness), nothing pending", desk: .single),
            panelScenario("3-displays", "Built-in + DELL (main, DDC) + LG (no control)"),
            panelScenario("3-displays-material", "As 3-displays, on a stand-in for the menu material",
                          dimmed: true, frame: .panelOnMaterial),
            panelScenario("3-displays-ic", "As 3-displays, Increase Contrast", looks: Look.increasedContrast),
            panelScenario("probing", "DELL's level still being read: Reading… in the empty rail") {
                dellBrightness($0, .probing)
            },
            panelScenario("unknown-level", "DELL answered but its level could not be read: — percent") {
                let id = dell($0).id
                dellBrightness($0, .available(control: FakeBrightness(displayID: id, backend: .ddc, level: 0.4),
                                              value: nil, readMs: nil))
            },
            panelScenario("empty", "No active displays", desk: .single) { $0.items = [] },
            panelScenario("pending-change", "Resolution change on DELL waiting for Keep: sections dimmed", dimmed: true) {
                $0.pending = pendingMode($0, secondsLeft: 12)
            },
            panelScenario("no-control-why", "LG has no brightness control; the info popover's content (diagnosis loaded)") {
                let lg = lg($0)
                let fake = Desk.lg(mirroring: nil)
                $0.diagnoses[lg.fingerprint] = DiagnosisState(report: fake.report, running: false)
            },
            panelScenario("disconnected", "Samsung disconnected by Keeplight: Disconnected section", disconnected: [Desk.samsung]),
            panelScenario("mirror-target", "LG mirrors DELL (hardware mirror target)", desk: .mirror),
            panelScenario("settling", "Waking: displays settling after wake, sections dimmed", dimmed: true) { $0.isSettling = true },
            panelScenario("receipt", "Receipt after the wake restore, with Undo") {
                $0.receipt = Receipt(text: Copy.wakeReceipt(name: "DELL U2723QE", percent: 40), undo: .entry("render-undo"),
                                     expires: Date().addingTimeInterval(60))
                undo($0)
            },
            panelScenario("receipt-1-display", "The owner's desk with a receipt and Undo", desk: .clamshell) {
                $0.receipt = Receipt(text: Copy.wakeReceipt(name: "BenQ EW3270U", percent: 72), undo: .entry("render-undo"),
                                     expires: Date().addingTimeInterval(60))
            },
            panelScenario("error", "An error row (re-commit failed)") {
                $0.errorMessage = Copy.lastsUntilQuit
            },
            panelScenario("pending-1-display", "The owner's desk, a resolution change waiting for Keep: locked",
                          desk: .clamshell, dimmed: true) {
                $0.pending = pendingMode($0, secondsLeft: 12, display: benq($0))
            },
            panelScenario("first-launch", "First launch: onboarding is its own window, the panel stays as it is") {
                $0.showFirstRun = true
            },
            panelScenario("safe-start", "⇧ held at launch: safe-start card above the panel") { $0.showSafeStart = true },
            panelScenario("long-name", "DELL renamed to a very long nickname (in-memory preferences)") {
                $0.prefs.nicknames[dell($0).fingerprint] = "Studio Display on the Left Arm Above the Drafting Table"
            },
            panelScenario("one-long-name", "One display with a very long name", desk: .single) {
                $0.prefs.nicknames[$0.items[0].fingerprint] = "Built-in Liquid Retina XDR Display of the Office MacBook"
            },
        ]
    }

    /// The popover behind the LG's info button, at its real width.
    static func whyPopover() -> Scenario {
        Scenario(name: "popover-no-control", surface: "Panel", state: "The No brightness control popover (diagnosis loaded)") { look in
            let model = Models.make(.three)
            let lg = lg(model)
            model.diagnoses[lg.fingerprint] = DiagnosisState(report: Desk.lg(mirroring: nil).report, running: false)
            return Renderer.render(WhyPopover(item: lg).environment(model), look: look, frame: .panel, width: 240, height: 84, settle: 0.5)
        }
    }

    // MARK: Keep card

    private static func keepScenario(_ name: String, _ state: String, title: String, phase: KeepCardState.Phase = .live,
                                     lit: Int = 15) -> Scenario {
        Scenario(name: "keep-\(name)", surface: "Keep card", state: state) { look in
            let card = KeepCardState(title: title, phase: phase, lit: lit)
            let width = Metrics.keepCardSize.width
            let view = KeepCardView(state: card)
            return Renderer.render(view, look: look, frame: .overlay, width: width,
                                   measure: { InstrumentPanel.fittingSize(of: view).height }, settle: 0.5)
        }
    }

    static func keep() -> [Scenario] {
        [
            keepScenario("mode-15", "Resolution change just applied, Fuse 15 of 15", title: "Keep 3008 × 1692?", lit: 15),
            keepScenario("mode-10", "Resolution change, Fuse 10 of 15", title: "Keep 3008 × 1692?", lit: 10),
            keepScenario("mode-03", "Resolution change, Fuse 3 of 15", title: "Keep 3008 × 1692?", lit: 3),
            keepScenario("mode-01", "Resolution change, last dot", title: "Keep 3008 × 1692?", lit: 1),
            keepScenario("mode-00", "Resolution change, Fuse spent", title: "Keep 3008 × 1692?", lit: 0),
            keepScenario("main", "Make DELL main", title: "Keep DELL U2723QE as main?", lit: 12),
            keepScenario("mirror", "Mirror", title: "Keep mirroring?", lit: 12),
            keepScenario("unmirror", "Stop mirroring", title: "Keep displays separate?", lit: 12),
            keepScenario("disconnect", "Disconnect LG", title: "Keep LG HDR 4K disconnected?", lit: 5),
            keepScenario("restore", "Restore a setup", title: "Keep this setup?", lit: 9),
            keepScenario("long-name", "Two-line title (long display name)",
                         title: "Keep \(Desk.builtinName) as main?", lit: 8),
            keepScenario("kept", "Kept: word and checkmark", title: "Keep 3008 × 1692?", phase: .kept, lit: 8),
            keepScenario("reverted", "Reverted: word and arrow", title: "Keep 3008 × 1692?", phase: .reverted, lit: 0),
        ]
    }

    // MARK: Identify

    static func identify() -> [Scenario] {
        [(Desk.builtinName, "builtin-long-name"), ("DELL U2723QE", "dell"), ("LG HDR 4K", "lg"),
         ("Samsung Odyssey Neo G9 Ultrawide Gaming Monitor 57 inch Dual 4K", "very-long")].map { name, slug in
            Scenario(name: "identify-\(slug)", surface: "Identify", state: name) { look in
                let view = IdentifyView(name: name)
                return Renderer.render(view, look: look, frame: .overlay, width: IdentifyView.width,
                                       measure: { InstrumentPanel.fittingSize(of: view).height }, settle: 0.5)
            }
        }
    }

    // MARK: Fuse

    static func fuse() -> [Scenario] {
        [15, 10, 1].map { lit in
            Scenario(name: "fuse-\(String(format: "%02d", lit))", surface: "Fuse", state: "\(lit) of 15 lit") { look in
                Renderer.render(Fuse(lit: lit).frame(width: 340, height: 60).instrumentPlate(), look: look,
                                frame: .overlay, width: 340, height: 60, settle: 0.3)
            }
        }
    }

    // MARK: Brightness OSD

    static func osd() -> [Scenario] {
        let levels = [0.0, 0.40, 0.75, 1.0].map { ($0, nil as String?) } + [(0.40, "DELL U2723QE" as String?)]
        return levels.map { value, name in
            let slug = String(format: "%03d", Int(value * 100)) + (name == nil ? "" : "-named")
            return Scenario(name: "osd-\(slug)", surface: "Brightness OSD",
                            state: "Brightness key, level \(Int(value * 100)) %" + (name == nil ? "" : ", two DDC displays")) { look in
                let state = BrightnessOSDState(value: value, name: name)
                return Renderer.render(BrightnessOSDView(state: state), look: look, frame: .overlay,
                                       width: BrightnessOSDView.width, height: BrightnessOSDView.height(named: name != nil),
                                       settle: 0.4)
            }
        }
    }

    // MARK: Rescue HUD

    static func rescue() -> [Scenario] {
        let cases: [(String, String, RescueHUDPhase)] = [
            ("5of5", "Holding, 5 of 5 dots", .holding(lit: 5)),
            ("3of5", "Holding, 3 of 5 dots", .holding(lit: 3)),
            ("1of5", "Holding, last dot", .holding(lit: 1)),
            ("done", "Done", .done(OverlayCopy.rescueRestored(displays: 2))),
        ]
        return cases.map { slug, state, phase in
            Scenario(name: "rescue-\(slug)", surface: "Rescue HUD", state: state) { look in
                Renderer.render(RescueHUDView(state: RescueHUDState(phase: phase)), look: look, frame: .overlay,
                                width: Metrics.rescueCardSize.width, height: Metrics.rescueCardSize.height, settle: 0.5)
            }
        }
    }

    // MARK: Status glyph

    static func glyph() -> [Scenario] {
        [("idle", false), ("pending", true)].map { slug, pending in
            Scenario(name: "glyph-\(slug)", surface: "Status glyph",
                     state: pending ? "Change pending: icon + \u{201C} Keep?\u{201D}" : "Idle") { look in
                Renderer.render(GlyphStrip(pending: pending, look: look), look: look, frame: .overlay,
                                width: GlyphStrip.size.width, height: GlyphStrip.size.height, settle: 0.1)
            }
        }
    }

    // MARK: Settings

    private static func settingsScenario(_ name: String, _ tab: SettingsTab, _ state: String,
                                         detailsOpen: Bool = false,
                                         _ configure: @escaping @MainActor (AppModel) -> Void = { _ in }) -> Scenario {
        Scenario(name: "settings-\(name)", surface: "Settings", state: state) { look in
            let model = Models.make(.three, disconnected: [Desk.samsung])
            model.settingsTab = tab
            configure(model)
            let pane = SettingsPane(tab: tab, detailsOpen: detailsOpen).environment(model)
            let size = SettingsWindowController.size(for: tab, model: model, detailsOpen: detailsOpen)
            return Renderer.render(pane, look: look, frame: .window, width: size.width, height: size.height, settle: 1.2)
        }
    }

    static func diagnosed(_ model: AppModel) {
        for fake in Desk.displays(.three) {
            model.diagnoses[fake.info.fingerprint] = DiagnosisState(report: fake.report, running: false)
        }
    }

    static func settings() -> [Scenario] {
        [
            settingsScenario("general-keys-off", .general, "General, brightness keys off (default)"),
            settingsScenario("general-menubar-off", .general, "General, menu bar item hidden, hotkey taken") {
                $0.prefs.showInMenuBar = false
                $0.hotKeyFailures = ["⌃⌥⌘D"]
            },
            settingsScenario("general-keys-waiting", .general, "General, brightness keys on, waiting for Accessibility") {
                $0.prefs.brightnessKeys = true
            },
            settingsScenario("general-keys-on", .general, "General, brightness keys on and running") {
                $0.prefs.brightnessKeys = true
                $0.brightnessKeysActive = true
            },
            settingsScenario("displays-ddc", .displays, "Displays, DELL selected: brightness by DDC/CI") {
                diagnosed($0)
                $0.settingsSelection = dell($0).fingerprint
            },
            settingsScenario("displays-ddc-details", .displays, "Displays, DELL selected, Details open", detailsOpen: true) {
                diagnosed($0)
                $0.settingsSelection = dell($0).fingerprint
            },
            settingsScenario("displays-builtin", .displays, "Displays, built-in selected: brightness by macOS") {
                diagnosed($0)
                $0.settingsSelection = $0.items.first { $0.info.isBuiltin }?.fingerprint
            },
            settingsScenario("displays-no-control", .displays, "Displays, LG selected: no brightness control (no DDC reply)") {
                diagnosed($0)
                $0.settingsSelection = lg($0).fingerprint
            },
            settingsScenario("displays-disconnected", .displays, "Displays, Samsung selected: disconnected") {
                $0.settingsSelection = Desk.samsung.fingerprint
            },
            settingsScenario("about", .about, "About, Details closed"),
            settingsScenario("about-keys-on", .about, "About, brightness keys running (Accessibility allowed)") {
                $0.prefs.brightnessKeys = true
                $0.brightnessKeysActive = true
            },
            settingsScenario("about-details", .about, "About, Details open", detailsOpen: true),
        ]
    }
}

/// The status item as it sits in the menu bar: the template icon tinted like the menu bar does,
/// with ` Keep?` while pending. Left: actual size (24 pt bar). Right below: magnified 5x.
struct GlyphStrip: NSViewRepresentable {
    static let size = CGSize(width: 260, height: 120)
    let pending: Bool
    let look: Look

    func makeNSView(context: Context) -> GlyphStripView { GlyphStripView(pending: pending, look: look) }
    func updateNSView(_ view: GlyphStripView, context: Context) {}
}

final class GlyphStripView: NSView {
    let pending: Bool
    let look: Look

    init(pending: Bool, look: Look) {
        self.pending = pending
        self.look = look
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func drawItem(at origin: NSPoint, scale: CGFloat) {
        let ink = look.isDark ? NSColor(white: 1, alpha: 0.95) : NSColor(white: 0, alpha: 0.85)
        let icon = StatusGlyph.image(pending: pending)
        let tinted = NSImage(size: icon.size, flipped: false) { r in
            icon.draw(in: r)
            ink.set()
            r.fill(using: .sourceIn)
            return true
        }
        let side = max(icon.size.width, icon.size.height) * scale
        tinted.draw(in: NSRect(x: origin.x, y: origin.y, width: side, height: side))
        guard pending else { return }
        let title = NSAttributedString(string: StatusItemController.pendingTitle, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0).withSize(13 * scale), .foregroundColor: ink])
        title.draw(at: NSPoint(x: origin.x + side, y: origin.y + (side - title.size().height) / 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        let barColor = look.isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        let bar = NSRect(x: 0, y: bounds.height - 24, width: bounds.width, height: 24)
        barColor.setFill()
        bar.fill()
        drawItem(at: NSPoint(x: 12, y: bar.midY - 8), scale: 1)
        let big = NSRect(x: 12, y: 2, width: bounds.width - 24, height: 90)
        barColor.setFill()
        big.fill()
        drawItem(at: NSPoint(x: 20, y: 12), scale: 3)
    }
}
#endif
