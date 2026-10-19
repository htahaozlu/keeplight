import AppKit
import QuartzCore

/// Tokens of the onboarding's custom surfaces (docs/design/v4-keeplight.md §1): the paper window,
/// the stage and its scenes. Standard controls keep the system colours. SF only.
enum OnboardingTheme {
    /// Light / Dark / Increase Contrast Light / Increase Contrast Dark.
    enum Variant: Equatable, Sendable {
        case light, dark, icLight, icDark
        var isDark: Bool { self == .dark || self == .icDark }
        var isHighContrast: Bool { self == .icLight || self == .icDark }
    }

    static func variant(for appearance: NSAppearance, increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) -> Variant {
        let v: Variant = switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                             .accessibilityHighContrastDarkAqua]) {
        case .darkAqua?: .dark
        case .accessibilityHighContrastAqua?: .icLight
        case .accessibilityHighContrastDarkAqua?: .icDark
        default: .light
        }
        if increaseContrast && !v.isHighContrast { return v.isDark ? .icDark : .icLight }
        return v
    }

    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    enum Token: CaseIterable, Sendable { case ink, ink2, ink3, inkWash, paper, paperRaised, hairline, signal }

    static func inkValue(_ v: Variant) -> NSColor {
        switch v {
        case .light: hex(0x111113)
        case .dark: hex(0xF5F5F3)
        case .icLight: hex(0x000000)
        case .icDark: hex(0xFFFFFF)
        }
    }

    /// One alpha per variant: light, dark, IC light, IC dark.
    private static func alpha(_ v: Variant, _ l: CGFloat, _ d: CGFloat, _ icl: CGFloat, _ icd: CGFloat) -> CGFloat {
        switch v { case .light: l; case .dark: d; case .icLight: icl; case .icDark: icd }
    }

    static func value(_ t: Token, _ v: Variant) -> NSColor {
        let ink = inkValue(v)
        switch t {
        case .ink: return ink
        case .ink2: return ink.withAlphaComponent(alpha(v, 0.62, 0.62, 0.80, 0.80))
        case .ink3: return ink.withAlphaComponent(alpha(v, 0.28, 0.30, 0.55, 0.60))
        case .inkWash: return ink.withAlphaComponent(alpha(v, 0.06, 0.08, 0.12, 0.14))
        case .paper:
            switch v {
            case .light: return hex(0xF7F7F5)
            case .dark: return hex(0x0B0B0C)
            case .icLight: return hex(0xFFFFFF)
            case .icDark: return hex(0x000000)
            }
        case .paperRaised: return v.isDark ? hex(0x161618) : hex(0xFFFFFF)
        case .hairline: return ink.withAlphaComponent(alpha(v, 0.12, 0.14, 0.45, 0.45))
        case .signal:
            switch v {
            case .light: return hex(0xE0301E)
            case .dark: return hex(0xFF4438)
            case .icLight: return hex(0xB8200F)
            case .icDark: return hex(0xFF6A5C)
            }
        }
    }

    /// A colour that follows the view's appearance (for AppKit text).
    static func dynamic(_ t: Token) -> NSColor {
        NSColor(name: nil) { appearance in value(t, variant(for: appearance)) }
    }

    // MARK: type (§1)

    enum Role: Hashable, Sendable {
        /// `Keeplight`: SF Display Bold 40/44, tracking −0.6.
        case wordmark
        /// 22/28 Semibold.
        case title
        /// 13/16.
        case body
        /// 12/15, secondary.
        case callout
        /// 11/14, scene labels.
        case caption
        /// 15/20 Semibold: card titles (the Keep card in the Fuse scene).
        case plate
    }

    static func font(_ role: Role) -> NSFont {
        switch role {
        case .wordmark: .systemFont(ofSize: 40, weight: .bold)
        case .title: .systemFont(ofSize: 22, weight: .semibold)
        case .body: .systemFont(ofSize: 13)
        case .callout: .systemFont(ofSize: 12)
        case .caption: .systemFont(ofSize: 11)
        case .plate: .systemFont(ofSize: 15, weight: .semibold)
        }
    }

    static func lineHeight(_ role: Role) -> CGFloat {
        switch role {
        case .wordmark: 44
        case .title: 28
        case .body: 16
        case .callout: 15
        case .caption: 14
        case .plate: 20
        }
    }

    static func attributes(_ role: Role, color: NSColor, alignment: NSTextAlignment = .natural) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight(role)
        p.maximumLineHeight = lineHeight(role)
        p.alignment = alignment
        p.lineBreakMode = .byTruncatingTail
        var a: [NSAttributedString.Key: Any] = [.font: font(role), .foregroundColor: color, .paragraphStyle: p]
        if role == .wordmark { a[.kern] = -0.6 }
        return a
    }

    // MARK: geometry and motion (§1, §4)

    enum Radius {
        static let control: CGFloat = 6
        static let group: CGFloat = 10
        static let stage: CGFloat = 12
    }

    enum Motion {
        /// Page transition D.
        static let page: Double = 320
        /// Reduce Motion cross-fades.
        static let reduced: Double = 150
    }
}

/// The onboarding's colours resolved for one appearance (static CGColors for layers; re-resolved
/// when the appearance or Increase Contrast changes).
struct StagePalette {
    let variant: OnboardingTheme.Variant
    let ink, ink2, ink3, inkWash, paper, paperRaised, hairline, signal: CGColor
    /// Pressed key fill (wash × 2) and the highlighted list row (ink α .04, IC .10).
    let inkPressed, inkHighlight: CGColor
    /// Edge of `paper.raised` surfaces: hairline; Increase Contrast 1 pt ink.
    let raisedEdge: CGColor

    /// The Keep card and the OSD are always-dark plates (§6), in both appearances.
    let plate, plateInk, plateInk2, plateSpent, plateSignal, plateButton, plateTrack: CGColor

    static func resolve(_ appearance: NSAppearance, increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) -> StagePalette {
        let v = OnboardingTheme.variant(for: appearance, increaseContrast: increaseContrast)
        func cg(_ t: OnboardingTheme.Token) -> CGColor { OnboardingTheme.value(t, v).cgColor }
        let ink = OnboardingTheme.inkValue(v)
        let wash = OnboardingTheme.value(.inkWash, v).alphaComponent
        return StagePalette(
            variant: v,
            ink: cg(.ink), ink2: cg(.ink2), ink3: cg(.ink3), inkWash: cg(.inkWash), paper: cg(.paper),
            paperRaised: cg(.paperRaised), hairline: cg(.hairline), signal: cg(.signal),
            inkPressed: ink.withAlphaComponent(wash * 2).cgColor,
            inkHighlight: ink.withAlphaComponent(v.isHighContrast ? 0.10 : 0.04).cgColor,
            raisedEdge: v.isHighContrast ? cg(.ink) : cg(.hairline),
            plate: NSColor(white: 0, alpha: 0.94).cgColor,
            plateInk: NSColor.white.cgColor,
            plateInk2: OnboardingTheme.hex(0x9A9A9F).cgColor,
            plateSpent: OnboardingTheme.hex(0x8E8E93).cgColor,
            plateSignal: OnboardingTheme.value(.signal, v.isHighContrast ? .icDark : .dark).cgColor,
            plateButton: NSColor(white: 1, alpha: 0.14).cgColor,
            plateTrack: OnboardingTheme.hex(0x636366).cgColor)
    }
}
