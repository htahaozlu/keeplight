import AppKit
import SwiftUI

/// Color tokens. Primary ink and separator come from the system. Secondary ink is our own: the
/// system `.secondary` measures 3.06:1 on the light panel, `inkSecondary` clears 4.5:1 on every
/// surface it sits on. There is no tertiary ink: secondary is the dimmest text color.
enum Palette {
    static var surfaceBase: NSColor { dynamic(light: 0xF2F2F0, dark: 0x0A0A0A) }
    static var inkPrimary: NSColor { .labelColor }
    static var inkSecondary: NSColor { dynamic(light: 0x5E5E62, dark: 0xA3A3A8, lightHC: 0x48484A, darkHC: 0xC7C7CC) }
    static var line: NSColor { .separatorColor }
    /// The only accent on the panel surface: lit Fuse dots (first run).
    static var signal: NSColor { dynamic(light: 0xE0301E, dark: 0xFF4438, lightHC: 0xB8200F, darkHC: 0xFF6A5C) }
    /// Keep card, Identify, OSD, rescue HUD: always dark, in both appearances.
    enum Instrument {
        static var plate: NSColor { NSColor(white: 0, alpha: 0.94) }
        static var ink: NSColor { .white }
        static var ink2: NSColor { hex(0x9A9A9F) }
        static var dotOff: NSColor { hex(0x2C2C2E) }
        static var signal: NSColor { hex(0xFF4438) }
        /// A spent Fuse dot: 1 pt outline, 3:1 non-text contrast on the plate.
        static var spent: NSColor { hex(0x8E8E93) }
    }

    /// The panel's tiles and controls (docs/design/v5-panel.md §1, §3): Control Center language on
    /// the `.menu` material. Alphas are on `ink` (#111113 / #F5F5F3; Increase Contrast #000 / #FFF).
    enum Panel {
        /// A module or notice tile on the material: white α.40 / α.07 (α.60 left the white
        /// slider fill with nothing to stand on in light mode).
        static var moduleFill: NSColor {
            dynamic { $0.isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 1, alpha: 0.40) }
        }
        /// The tile under Reduce Transparency: `paper.raised`.
        static var moduleFillOpaque: NSColor { dynamic { $0.isDark ? hex(0x161618) : hex(0xFFFFFF) } }
        /// 0.5 pt inside the tile: `hairline` at half alpha.
        static var moduleHairline: NSColor { ink(0.06, 0.07, ic: 0.45) }
        /// `hairline`: the slider track, and the 1 pt edge of a chip under Increase Contrast.
        static var hairline: NSColor { ink(0.16, 0.14, ic: 0.45) }
        /// An empty rail (no control, reading) carries secondary text, so it is `ink.wash`, not the
        /// track: the text keeps 4.5:1, and the rail reads as idle next to a live track. Under
        /// Increase Contrast its edge comes from `contrastEdge`.
        static var rail: NSColor { wash(.rest) }
        /// The lit part of the slider: white in both appearances, like Control Center.
        static var sliderFill: NSColor { .white }
        /// 0.5 pt inside the slider capsule, so the white fill keeps its outline on a white tile
        /// (light, Reduce Transparency, Increase Contrast). Nothing in dark: the fill stands out.
        static var sliderEdge: NSColor { ink(0.14, 0, ic: 0.45) }
        /// Edges that exist only under Increase Contrast (chips, the empty rail): 1 pt `hairline`.
        static var contrastEdge: NSColor { ink(0, 0, ic: 0.45) }
        /// `sun.max` on the white fill.
        static var sliderGlyph: NSColor { hex(0x111113) }
        /// `ink.wash` behind a chip at rest, under the pointer and pressed.
        static func wash(_ state: ControlState) -> NSColor {
            switch state {
            case .rest: ink(0.08, 0.08, ic: 0.10)
            case .hover: ink(0.12, 0.14, ic: 0.14)
            case .pressed: ink(0.18, 0.20, ic: 0.20)
            }
        }

        private static func ink(_ light: CGFloat, _ dark: CGFloat, ic: CGFloat) -> NSColor {
            dynamic { variant in
                switch variant {
                case .light: hex(0x111113, alpha: light)
                case .dark: hex(0xF5F5F3, alpha: dark)
                case .lightHC: hex(0x000000, alpha: ic)
                case .darkHC: hex(0xFFFFFF, alpha: ic)
                }
            }
        }

        private static func dynamic(_ provider: @escaping (Variant) -> NSColor) -> NSColor {
            NSColor(name: nil) { provider(variant($0)) }
        }
    }

    enum Variant {
        case light, dark, lightHC, darkHC
        var isDark: Bool { self == .dark || self == .darkHC }
        var isHighContrast: Bool { self == .lightHC || self == .darkHC }
    }

    static func variant(_ appearance: NSAppearance) -> Variant {
        let variant: Variant = switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                                  .accessibilityHighContrastDarkAqua]) {
        case .darkAqua?: .dark
        case .accessibilityHighContrastDarkAqua?: .darkHC
        case .accessibilityHighContrastAqua?: .lightHC
        default: .light
        }
        #if DEBUG
        if forcedHighContrast, !variant.isHighContrast { return variant.isDark ? .darkHC : .lightHC }
        #endif
        return variant
    }

    #if DEBUG
    /// The render tool draws Increase Contrast with this: AppKit hands out a high-contrast
    /// appearance only while the system setting is on, never from `NSAppearance(named:)`.
    nonisolated(unsafe) static var forcedHighContrast = false
    #endif

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    private static func dynamic(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            switch variant(appearance) {
            case .light: hex(light)
            case .dark: hex(dark)
            case .lightHC: hex(lightHC ?? light)
            case .darkHC: hex(darkHC ?? dark)
            }
        }
    }
}

extension Color {
    static var inkPrimary: Color { .primary }
    static var inkSecondary: Color { Color(nsColor: Palette.inkSecondary) }
    static var line: Color { Color(nsColor: Palette.line) }

    enum Panel {
        static var moduleFill: Color { Color(nsColor: Palette.Panel.moduleFill) }
        static var moduleFillOpaque: Color { Color(nsColor: Palette.Panel.moduleFillOpaque) }
        static var moduleHairline: Color { Color(nsColor: Palette.Panel.moduleHairline) }
        static var hairline: Color { Color(nsColor: Palette.Panel.hairline) }
        static var rail: Color { Color(nsColor: Palette.Panel.rail) }
        static var sliderFill: Color { Color(nsColor: Palette.Panel.sliderFill) }
        static var sliderGlyph: Color { Color(nsColor: Palette.Panel.sliderGlyph) }
        static func wash(_ state: ControlState) -> Color { Color(nsColor: Palette.Panel.wash(state)) }
    }

    enum Instrument {
        static var plate: Color { Color(nsColor: Palette.Instrument.plate) }
        static var ink: Color { .white }
        static var ink2: Color { Color(nsColor: Palette.Instrument.ink2) }
        static var dotOff: Color { Color(nsColor: Palette.Instrument.dotOff) }
        static var signal: Color { Color(nsColor: Palette.Instrument.signal) }
        static var spent: Color { Color(nsColor: Palette.Instrument.spent) }
    }
}

/// How a control looks under the pointer (`hover`) and while the mouse is down (`pressed`).
enum ControlState: Equatable, Sendable { case rest, hover, pressed }

/// Spacing and radii [O§3.6, v5 §1]. Radii are concentric (module = panel − inset); macOS 26+ is
/// rounder, like its system windows.
enum Metrics {
    static let panelWidth: CGFloat = 320
    /// Panel edge → tile edge on every side, and the gap between tiles.
    static let inset: CGFloat = 6
    /// Inside a tile: 12 left and right (content 284 wide), 10 top and bottom.
    static let moduleHPadding: CGFloat = 12
    static let moduleVPadding: CGFloat = 10
    static let moduleWidth: CGFloat = panelWidth - 2 * inset
    static let moduleContentWidth: CGFloat = moduleWidth - 2 * moduleHPadding
    /// Rows of a display module: name (24), 6, slider (28, the capsule 24 centred), 6, chip (24).
    static let headerRow: CGFloat = 24
    static let sliderRow: CGFloat = 28
    static let chipRow: CGFloat = 24
    static let rowGap: CGFloat = 6
    /// Every display module, whatever its state: the rail keeps its slot so modules line up.
    static let moduleHeight: CGFloat = 2 * moduleVPadding + headerRow + rowGap + sliderRow + rowGap + chipRow
    /// A mirror target or a disconnected display: name and one row, no resolution chip.
    static let compactModuleHeight: CGFloat = 2 * moduleVPadding + headerRow + rowGap + sliderRow
    /// Content of a locked module (a change waits for Keep, the displays wake).
    static let lockedOpacity: Double = 0.5
    static let noticeHPadding: CGFloat = 12
    static let noticeVPadding: CGFloat = 8
    static let noticeMinHeight: CGFloat = 36
    /// `Waking…` and the floor caption, between the modules and the footer.
    static let lineHeight: CGFloat = 24
    static let footerHeight: CGFloat = 32
    /// The capsule of every chip and the slider.
    static let chipHeight: CGFloat = 24
    static let chipHPadding: CGFloat = 10
    /// Slider row: track, 8, percent (30, right-aligned) = the module's content width.
    static let sliderGap: CGFloat = 8
    static let percentWidth: CGFloat = 30
    static let sliderTrackWidth: CGFloat = moduleContentWidth - sliderGap - percentWidth
    /// Smallest interactive target in either dimension (visual size may be smaller).
    static let minTarget: CGFloat = 24
    /// Label minimum height inside a `.bordered` button so the whole control reaches `minTarget`
    /// (the bezel adds its own padding).
    static let smallLabelHeight: CGFloat = 18
    static let regularLabelHeight: CGFloat = 16
    static let keepCardSize = CGSize(width: 340, height: 132)
    static let rescueCardSize = CGSize(width: 340, height: 112)
    static let cardRadius: CGFloat = 20
    static let fuseDot: CGFloat = 8
    static let fusePitch: CGFloat = 18
    static let fuseCount = 15

    static var isMacOS26: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 18 on macOS 26, 16 before: 12 left too little room for a concentric tile radius.
    static var panelRadius: CGFloat { isMacOS26 ? 18 : 16 }
    /// Concentric with the panel: 12 / 10 (the `stage` / `group` radii).
    static var moduleRadius: CGFloat { panelRadius - inset }
    static var controlRadius: CGFloat { isMacOS26 ? 6 : 5 }
}

/// The panel's heights per state (v5 §1), so the window size is known without a layout pass and
/// tests can hold the views to it. The panel stacks, top to bottom: inset, the notice tile and a
/// gap (when there is one), the modules with a gap between them, a gap, the `Waking…` line (when
/// shown), the footer, inset.
enum PanelLayout {
    /// `modules` tiles of `Metrics.moduleHeight`, of which `compact` (mirror targets, disconnected
    /// displays) are `Metrics.compactModuleHeight` (an empty desk shows one full tile).
    static func height(modules: Int, compact: Int = 0, notice: CGFloat? = nil, line: Bool = false) -> CGFloat {
        let tiles = max(modules, 1)
        let short = modules == 0 ? 0 : min(compact, tiles)
        var height = Metrics.inset
        if let notice { height += max(notice, Metrics.noticeMinHeight) + Metrics.inset }
        height += CGFloat(tiles - short) * Metrics.moduleHeight + CGFloat(short) * Metrics.compactModuleHeight
        height += CGFloat(tiles - 1) * Metrics.inset
        height += Metrics.inset
        if line { height += Metrics.lineHeight }
        return height + Metrics.footerHeight + Metrics.inset
    }

    /// A notice tile with one line of callout text next to a chip: the chip (24) and 8 above and below.
    static let noticeWithChip: CGFloat = Metrics.chipHeight + 2 * Metrics.noticeVPadding
}

/// Type roles: system fonts only. Numbers use monospaced digits.
extension Font {
    static let titlePlate = Font.system(size: 13, weight: .semibold)
    static let bodyText = Font.system(size: 13).monospacedDigit()
    static let captionText = Font.system(size: 11)
    /// Callout, 12 pt (v4 §1): `Waking…`, notices, the empty rail.
    static let callout12 = Font.system(size: 12)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let identify = Font.system(size: 40, weight: .semibold)
}
