#if DEBUG
import AppKit
import SwiftUI
@testable import KeeplightUI

/// A window that is never ordered in: drawing happens through `cacheDisplay(in:to:)` only.
/// Ordering methods refuse (logged), so a stray call can't put it on screen. The backing scale is
/// pinned to 2 so layer contents rasterize at 2× whatever screen the Mac has.
final class OffscreenWindow: NSWindow {
    init(size: CGSize, appearance: NSAppearance) {
        // Far outside any screen; never ordered in anyway.
        super.init(contentRect: NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        self.appearance = appearance
    }

    override var backingScaleFactor: CGFloat { 2 }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func orderFront(_ sender: Any?) { RefusalLog.shared.record("NSWindow.orderFront") }
    override func orderFrontRegardless() { RefusalLog.shared.record("NSWindow.orderFrontRegardless") }
    override func makeKeyAndOrderFront(_ sender: Any?) { RefusalLog.shared.record("NSWindow.makeKeyAndOrderFront") }
    override func orderBack(_ sender: Any?) { RefusalLog.shared.record("NSWindow.orderBack") }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place == .out else { return RefusalLog.shared.record("NSWindow.order(\(place.rawValue))") }
        super.order(place, relativeTo: otherWin)
    }
}

enum Look: String, CaseIterable {
    case light, dark
    /// Increase Contrast.
    case lightIC = "light-ic", darkIC = "dark-ic"

    static let standard: [Look] = [.light, .dark]
    static let increasedContrast: [Look] = [.lightIC, .darkIC]

    var isDark: Bool { self == .dark || self == .darkIC }
    var isIncreasedContrast: Bool { self == .lightIC || self == .darkIC }

    /// Increase Contrast looks use the standard appearance (`NSAppearance(named:)` never returns
    /// a high-contrast one) with `Palette.forcedHighContrast` set while they render.
    var appearance: NSAppearance { NSAppearance(named: isDark ? .darkAqua : .aqua)! }

    /// What sits behind an overlay or the panel: a plain desktop.
    var backdrop: NSColor { isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.86, alpha: 1) }

    /// A rough stand-in for the `.menu` material over that desktop (the window server draws the
    /// real one, which cannot be captured offscreen); for judging the translucent tile tokens,
    /// not a measurement.
    var material: NSColor { isDark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.925, alpha: 1) }
}

/// How the captured view is framed.
enum Frame {
    /// The panel: content in `PanelMaterial.container` (Reduce Transparency form), on a backdrop.
    case panel
    /// The panel as it looks on the material (no Reduce Transparency): the same container, its
    /// fill set to `Look.material`, the tiles in their translucent form.
    case panelOnMaterial
    /// Instrument overlays and the status glyph: on a backdrop with a margin.
    case overlay
    /// A Settings tab: window background, exact content size.
    case window
}

/// Layer-backed solid fill that resolves its color in the view's appearance.
final class FillView: NSView {
    let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }
}

struct Capture {
    let image: NSBitmapImageRep
    /// The hosting view (still in its offscreen window).
    let host: NSView
    /// Frames of the interactive controls, reported by the views while they were laid out.
    let sink: TargetSink
    let window: NSWindow
    /// Content size in points (without the backdrop margin).
    let contentSize: CGSize
    let margin: CGFloat
}

@MainActor
enum Renderer {
    static let scale: CGFloat = 2
    static var windows: [NSWindow] = []

    /// Renders `view` offscreen. `width` fixes the width; height is the view's fitting height
    /// unless `height` is given. `settle` lets tasks, onAppear work and animations finish.
    static func render<V: View>(_ view: V, look: Look, frame: Frame, width: CGFloat, height: CGFloat? = nil,
                                measure: (@MainActor () -> CGFloat)? = nil, settle: TimeInterval = 0.45,
                                controlState: ControlState? = nil) -> Capture {
        // Increase Contrast: the palette's own variants (see `Palette.forcedHighContrast`); the
        // system colors (primary ink, separators) keep their standard form.
        Palette.forcedHighContrast = look.isIncreasedContrast
        defer { Palette.forcedHighContrast = false }
        let sink = TargetSink()
        let root = view
            .environment(\.targetSink, sink)
            .environment(\.displayScale, scale)
            .environment(\._accessibilityReduceTransparency, frame == .panel)
            .environment(\.forcedControlState, controlState)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let margin: CGFloat = frame == .window ? 0 : 16
        func outer(_ size: CGSize) -> CGSize { CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin) }
        var size = CGSize(width: width, height: height ?? 900)
        let window = OffscreenWindow(size: outer(size), appearance: look.appearance)
        let container: NSView
        var surface: PanelSurfaceView?
        switch frame {
        case .panel, .panelOnMaterial:
            // The app's own container (`PanelController` uses the same call), in its Reduce
            // Transparency form: the material itself is drawn by the window server, not here.
            host.frame = NSRect(origin: .zero, size: size)
            surface = PanelMaterial.container(wrapping: host, opaque: true)
            container = surface!
        case .overlay:
            container = host
        case .window:
            container = FillView(color: .windowBackgroundColor)
        }
        // Frames first, then the autoresizing masks: a mask applied to a zero-sized parent that is
        // then given its frame would resize the child a second time.
        container.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        if container !== host, surface == nil {
            host.frame = NSRect(origin: .zero, size: size)
            container.addSubview(host)
            host.autoresizingMask = [.width, .height]
        }
        let backdrop = FillView(color: frame == .window ? .windowBackgroundColor : look.backdrop)
        backdrop.frame = NSRect(origin: .zero, size: outer(size))
        backdrop.addSubview(container)
        container.autoresizingMask = [.width, .height]
        window.contentView = backdrop

        // First layout: onAppear work, geometry callbacks (the panel reports its natural height).
        pump(settle, backdrop)
        if height == nil {
            size.height = ceil(measure?() ?? host.fittingSize.height)
            window.setContentSize(outer(size))
            pump(0.3, backdrop)
        }

        if frame == .panelOnMaterial, let fill = surface?.fill.shapeLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.fillColor = look.material.cgColor
            CATransaction.commit()
        }

        // `cacheDisplay(in:to:)` only replays `draw(_:)`, which skips SwiftUI's own layers, so the
        // committed layer tree is rendered instead (CGDrawingLayer, RBDrawingLayer and AppKit
        // backing stores all draw into a CGContext).
        let rep = renderLayers(of: backdrop, size: outer(size), look: look)
        precondition(!window.isVisible, "an offscreen window became visible")
        windows.append(window)
        return Capture(image: rep, host: host, sink: sink, window: window, contentSize: size, margin: margin)
    }

    static func renderLayers(of view: NSView, size: CGSize, look: Look) -> NSBitmapImageRep {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        if let layer = view.layer {
            if layer.isGeometryFlipped {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
            }
            look.appearance.performAsCurrentDrawingAppearance { layer.render(in: context) }
        }
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        rep.size = size
        return rep
    }

    /// Spins the main run loop so SwiftUI commits, tasks run and timelines advance.
    static func pump(_ seconds: TimeInterval, _ view: NSView) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        } while Date() < end
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    static func png(_ rep: NSBitmapImageRep) -> Data {
        rep.representation(using: .png, properties: [:])!
    }

    /// No window of this process may ever be visible.
    static var visibleWindows: [NSWindow] { NSApp.windows.filter(\.isVisible) }
}
#endif
