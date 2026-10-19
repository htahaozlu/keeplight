import AppKit
import DisplayCore
import SwiftUI

/// An `NSMenuItem` that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, enabled: Bool = true, state: NSControl.StateValue = .off,
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        self.state = state
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

@MainActor
extension NSMenu {
    /// Pops the menu up at the pointer.
    func popUpAtPointer() {
        autoenablesItems = false
        popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Interaction state

private struct ForcedControlStateKey: EnvironmentKey {
    static let defaultValue: ControlState? = nil
}

extension EnvironmentValues {
    /// Shows every control of a subtree in one state. Only the render tool sets it (hover and
    /// pressed cannot be captured offscreen); in the app it is nil and the live state shows.
    var forcedControlState: ControlState? {
        get { self[ForcedControlStateKey.self] }
        set { self[ForcedControlStateKey.self] = newValue }
    }
}

/// Tracks the pointer over a control and animates what depends on it with `Tween.hover`.
private struct HoverTracking: ViewModifier {
    @Binding var hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .animation(Tween.hover.animation(reduceMotion: reduceMotion), value: hovering)
    }
}

extension View {
    func trackingHover(_ hovering: Binding<Bool>) -> some View { modifier(HoverTracking(hovering: hovering)) }
}

// MARK: - Tiles

/// A module or notice tile (v5 §1): `moduleRadius`, concentric with the panel; white wash on the
/// material, `paper.raised` under Reduce Transparency; a 0.5 pt hairline inside the shape. No
/// shadow, no blur of our own.
struct TileBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.moduleRadius, style: .circular)
        shape.fill(reduceTransparency ? Color.Panel.moduleFillOpaque : Color.Panel.moduleFill)
            .overlay(shape.strokeBorder(Color.Panel.moduleHairline, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

// MARK: - Chips

/// A capsule's edge, `width` wide inside the shape: the capsule minus the capsule inset by
/// `width`, filled even-odd. A stroked capsule picks up a stray 1 px line at its ends where the
/// straight sides have zero length; a filled ring has no such segment.
struct CapsuleEdge: Shape {
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .circular)
        let inner = rect.insetBy(dx: width, dy: width)
        path.addPath(Path(roundedRect: inner, cornerRadius: inner.height / 2, style: .circular))
        return path
    }
}

extension View {
    /// `color` as a capsule edge `width` wide over this view.
    func capsuleEdge(_ color: NSColor, width: CGFloat) -> some View {
        overlay(CapsuleEdge(width: width).fill(Color(nsColor: color), style: FillStyle(eoFill: true)))
    }
}

/// The capsule behind every chip: `ink.wash` by state; a 1 pt `hairline` under Increase Contrast.
struct ChipCapsule: View {
    let state: ControlState

    var body: some View {
        Capsule().fill(Color.Panel.wash(state))
            .capsuleEdge(Palette.Panel.contrastEdge, width: 1)
    }
}

/// The one small button of the panel (v5 §3): a 24-tall capsule, 13 pt primary text, 10 pt
/// sides. Hover lifts the wash in 120 ms; pressed is immediate. Never filled: the only prominent
/// button of the app is `Keep`.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration) }

    private struct ChipBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.forcedControlState) private var forced

        var body: some View {
            let state = forced ?? (configuration.isPressed ? .pressed : hovering ? .hover : .rest)
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(Color.inkPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Metrics.chipHPadding)
                .frame(minWidth: Metrics.chipHeight, minHeight: Metrics.chipHeight)
                .background(ChipCapsule(state: state))
                .contentShape(Capsule())
                .trackingHover($hovering)
        }
    }
}

/// A chip with a title (`Undo`, `Reconnect`, `Stop Mirroring`, `Rescue`, `Continue`, `Check Again`).
struct Chip: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(ChipButtonStyle())
            .hitTarget(title)
    }
}

/// A label that is its own button: α.6 while pressed, nothing else. Unlike `.plain` it does not
/// dim itself when disabled, so a locked module's content fades by exactly its .45, controls and
/// text alike. Menus use it for their label too.
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Text buttons on the bare material (footer, dismiss): secondary ink, primary under the pointer,
/// α.6 while pressed.
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { InkBody(configuration: configuration) }

    private struct InkBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.forcedControlState) private var forced

        var body: some View {
            let state = forced ?? (configuration.isPressed ? .pressed : hovering ? .hover : .rest)
            configuration.label
                .foregroundStyle(state == .rest ? Color.inkSecondary : Color.inkPrimary)
                .opacity(state == .pressed ? 0.6 : 1)
                .trackingHover($hovering)
        }
    }
}

// MARK: - Capsule slider

/// The capsule slider's geometry (v5 §3), pure so tests hold the view to it. The track is 24
/// tall; the white fill is left-anchored and never narrower than the 24 × 24 glyph square, so a
/// level of 0…1 maps to a fill of 24…`width`; the pointer sits on the centre of the fill's end.
struct CapsuleSliderGeometry: Equatable, Sendable {
    var width: CGFloat = Metrics.sliderTrackWidth
    var height: CGFloat = Metrics.chipHeight

    /// The distance the fill's end travels: 222 on the 246 track.
    var span: CGFloat { width - height }

    func fillWidth(_ level: Double) -> CGFloat { height + span * CGFloat(BrightnessPolicy.clamp(level)) }

    /// The level under `x` (points from the track's leading edge): a press jumps here.
    func level(atX x: CGFloat) -> Double {
        guard span > 0 else { return 0 }
        return BrightnessPolicy.clamp(Double((x - height / 2) / span))
    }
}

/// Keys of a focused capsule slider: ← → (and ↓ ↑) one brightness-key step (1/16), with ⌥⇧ one
/// fine step (1/64); Home / End the ends. `floor` is the lowest level the display may take.
enum CapsuleSliderKey: Equatable, Sendable {
    case decrement, increment, home, end

    func level(from value: Double, fine: Bool, floor: Double) -> Double {
        switch self {
        case .decrement: BrightnessPolicy.keyed(from: value, up: false, fine: fine, floor: floor)
        case .increment: BrightnessPolicy.keyed(from: value, up: true, fine: fine, floor: floor)
        case .home: BrightnessPolicy.clamp(0, floor: floor)
        case .end: 1
        }
    }

    init?(_ key: KeyEquivalent) {
        switch key {
        case .leftArrow, .downArrow: self = .decrement
        case .rightArrow, .upArrow: self = .increment
        case .home: self = .home
        case .end: self = .end
        default: return nil
        }
    }

    static let keys: Set<KeyEquivalent> = [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]

    /// The quarter step of the brightness keys: ⌥ and ⇧ together.
    /// ⌥ (with or without ⇧, as the brightness keys): quarter steps.
    static func isFine(_ modifiers: EventModifiers) -> Bool { modifiers.contains(.option) }
}

/// Control Center's brightness slider (v5 §3): a 246 × 24 capsule track (`hairline`), a white
/// fill with `sun.max` in its first 24 × 24, no thumb; the percent to its right in monospaced
/// digits, secondary ink, primary while the pointer is over the track or a drag is live, `—`
/// when the level is unknown. A press jumps to the pointer and drags from there.
struct CapsuleSlider: View {
    /// nil: the level could not be read.
    let value: Double?
    let floor: Double
    /// Whether the panel is on screen; nothing animates otherwise.
    let visible: Bool
    let onChange: (Double) -> Void
    let onDrag: (_ began: Bool) -> Void

    @State private var dragging = false
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.forcedControlState) private var forced

    private let geometry = CapsuleSliderGeometry()

    var body: some View {
        let level = value ?? 0
        let percent = value.map(BrightnessPolicy.percent)
        let active = forced.map { $0 != .rest } ?? (hovering || dragging)
        HStack(spacing: Metrics.sliderGap) {
            track(level: level, percent: percent)
            Text(percent.map(String.init) ?? "—")
                .font(.bodyText)
                .foregroundStyle(active ? Color.inkPrimary : Color.inkSecondary)
                .frame(width: Metrics.percentWidth, alignment: .trailing)
                .animation(Tween.hover.animation(reduceMotion: reduceMotion, visible: visible), value: active)
                .accessibilityHidden(true)
        }
        .frame(height: Metrics.sliderRow)
    }

    private func track(level: Double, percent: Int?) -> some View {
        let fill = Tween.sliderFill.animation(reduceMotion: reduceMotion, visible: visible && !dragging)
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.Panel.hairline)
            Capsule().fill(Color.Panel.sliderFill)
                .frame(width: geometry.fillWidth(level))
                .animation(fill, value: level)
            Image(systemName: "sun.max")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.Panel.sliderGlyph)
                .frame(width: geometry.height, height: geometry.height)
        }
        .frame(width: geometry.width, height: geometry.height)
        .capsuleEdge(Palette.Panel.sliderEdge, width: 0.5)
        .overlay {
            if focused {
                CapsuleEdge(width: 3).fill(Color.inkPrimary.opacity(0.45), style: FillStyle(eoFill: true))
                    .padding(-3)
            }
        }
        .contentShape(Capsule())
        .gesture(drag)
        .onHover { hovering = $0 }
        .focusable(interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: CapsuleSliderKey.keys, phases: [.down, .repeat]) { press in
            guard let key = CapsuleSliderKey(press.key) else { return .ignored }
            onChange(key.level(from: value ?? 0, fine: CapsuleSliderKey.isFine(press.modifiers), floor: floor))
            return .handled
        }
        .hitTarget("Brightness slider")
        .accessibilityElement()
        .accessibilityLabel("Brightness")
        .accessibilityValue(percent.map { "\($0) percent" } ?? "unknown")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(CapsuleSliderKey.increment.level(from: value ?? 0, fine: false, floor: floor))
            case .decrement: onChange(CapsuleSliderKey.decrement.level(from: value ?? 0, fine: false, floor: floor))
            @unknown default: break
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { gesture in
                if !dragging {
                    dragging = true
                    onDrag(true)
                }
                onChange(geometry.level(atX: gesture.location.x))
            }
            .onEnded { _ in
                dragging = false
                onDrag(false)
            }
    }
}

/// The empty rail in the slider's slot (reading, no control): the same 246 × 24 capsule, a light
/// wash, its edge from `hairline` under Increase Contrast.
struct RailBackground: View {
    var body: some View {
        Capsule().fill(Color.Panel.rail)
            .capsuleEdge(Palette.Panel.contrastEdge, width: 1)
    }
}
