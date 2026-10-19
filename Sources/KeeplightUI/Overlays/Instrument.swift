import AppKit
import QuartzCore
import SwiftUI

/// A borderless panel for the always-dark overlay cards (Keep card, Identify, OSD, rescue HUD).
/// One per screen at `.popUpMenu`, on every Space and above full-screen apps. The SwiftUI
/// content sits in `OverlayContainer`, whose layer a `Timeline` animates.
final class InstrumentPanel: NSPanel {
    private let interactive: Bool
    private(set) var container: OverlayContainer?
    /// Bumped by every `play`; a stale completion sees a different value and does nothing.
    fileprivate var generation = 0
    fileprivate var holdTask: Task<Void, Never>?

    init(frame: NSRect, interactive: Bool) {
        self.interactive = interactive
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = interactive
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = !interactive
        animationBehavior = .none
        isFloatingPanel = true
    }

    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { false }

    /// Hosts `view`; size the panel with `fittingSize(of:)`.
    func host<V: View>(_ view: V) {
        // The Keep card's buttons work on the first click even before the card is key.
        let host = FirstClickHostingView(rootView: view)
        host.sizingOptions = []
        let container = OverlayContainer(host: host)
        contentView = container
        self.container = container
    }

    /// The size `view` wants (its width is fixed by the view itself).
    @MainActor
    static func fittingSize<V: View>(of view: V) -> CGSize { NSHostingView(rootView: view).fittingSize }

    // MARK: Placement

    /// Top edge at `fraction` of the screen height below the top (the Keep card sits at 0.36).
    static func frame(size: CGSize, on screen: NSScreen, topFraction fraction: CGFloat) -> NSRect {
        let frame = screen.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * fraction - size.height,
                      width: size.width, height: size.height)
    }

    /// Vertical center at `fraction` of the screen height below the top (Identify, rescue: 0.40).
    static func frame(size: CGSize, on screen: NSScreen, centerFraction fraction: CGFloat) -> NSRect {
        let frame = screen.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * fraction - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Motion

    /// The pose on screen now (the layer's presentation), or the resting pose when idle.
    var shownPose: Pose {
        guard let layer = container?.hostLayer else { return Pose(opacity: 0) }
        return Pose(presentationOf: layer)
    }

    /// Puts the window at `pose` without animating (before it is ordered in).
    func set(pose: Pose) {
        guard let layer = container?.hostLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.opacity = Float(pose.opacity)
        layer.transform = CATransform3DMakeScale(pose.scale, pose.scale, 1)
        CATransaction.commit()
    }

    /// Plays `timeline` on the window's layer and calls `completion` when it has finished.
    ///
    /// - An animation already in flight is continued from the pose on screen, not restarted.
    /// - When nothing may animate (Reduce Motion, occluded, app hidden, screens asleep) the
    ///   timeline's explanation pose is set; a timeline that ends hidden then waits `staticHold`
    ///   seconds (one cancellable task, not an animation) before `completion`.
    func play(_ timeline: Timeline, staticHold: TimeInterval = 0, completion: @escaping @MainActor () -> Void = {}) {
        guard let layer = container?.hostLayer else { return completion() }
        holdTask?.cancel()
        holdTask = nil
        generation += 1
        let ticket = generation
        let interrupted = layer.animationKeys()?.isEmpty == false
        let timeline = interrupted ? timeline.continuing(from: shownPose) : timeline
        guard mayAnimate else {
            set(pose: timeline.explanationPose)
            if timeline.resting == timeline.explanationPose { return completion() }
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(staticHold))
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                completion()
            }
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == ticket else { return }
                completion()
            }
        }
        timeline.run(on: layer, key: "overlay", animated: true)
        CATransaction.commit()
    }

    /// The gate for a window that floats above everything on every Space: it cannot be covered, and
    /// `occlusionState` has not caught up right after it is ordered in, so occlusion is not asked.
    var mayAnimate: Bool {
        AnimationGate.mayAnimate(windowVisible: isVisible && !isMiniaturized, occluded: false,
                                 appHidden: NSApp?.isHidden ?? false, screensAwake: AnimationGate.screensAwake,
                                 reduceMotion: AnimationGate.reduceMotion)
    }

    /// Stops motion and any pending hold; the window keeps its current pose.
    func cancelPlayback() {
        holdTask?.cancel()
        holdTask = nil
        generation += 1
        container?.hostLayer?.removeAllAnimations()
    }
}

extension Timeline {
    /// The same timeline starting from `pose` (an interrupted animation continuing from what is
    /// on screen).
    func continuing(from pose: Pose) -> Timeline {
        var frames = keyframes
        frames[0] = Keyframe(time: 0, pose: pose, easing: frames[0].easing)
        return Timeline(keyframes: frames, easing: easing, loops: loops, explanationTime: explanationTime)
    }
}

/// Content view of an overlay window. The hosting view's layer scales about its center.
final class OverlayContainer: NSView {
    private let host: NSView

    init(host: NSView) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var hostLayer: CALayer? { host.layer }

    override func layout() {
        super.layout()
        guard let layer = host.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: host.frame.midX, y: host.frame.midY)
    }
}

/// The overlay plate: black (opaque under Reduce Transparency) with a 1 px inner hairline.
struct InstrumentPlate: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = Metrics.cardRadius
    var opacity: Double = 0.94
    var style: RoundedCornerStyle = .continuous

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: style)
        content
            .background(shape.fill(reduceTransparency ? Color.black : Color.black.opacity(opacity)))
            .overlay(shape.inset(by: 0.5).stroke(Color.white.opacity(0.10), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func instrumentPlate(radius: CGFloat = Metrics.cardRadius, opacity: Double = 0.94,
                         style: RoundedCornerStyle = .continuous) -> some View {
        modifier(InstrumentPlate(radius: radius, opacity: opacity, style: style))
    }
}

/// Keep card buttons, 96 × 28: `Revert` is a translucent white fill, `Keep` a white fill with
/// black text (the one prominent button).
struct CardButtonStyle: ButtonStyle {
    static let size = CGSize(width: 96, height: 28)
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.black : Color.Instrument.ink)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(prominent ? Color.Instrument.ink : Color.white.opacity(0.16)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
