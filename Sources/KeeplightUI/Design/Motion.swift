import AppKit
import QuartzCore
import SwiftUI

/// Cubic-bezier easing with control points (c1x, c1y, c2x, c2y), CSS / `CAMediaTimingFunction` style.
struct Easing: Equatable, Sendable {
    let c1x: Double, c1y: Double, c2x: Double, c2y: Double

    static let linear = Easing(c1x: 0, c1y: 0, c2x: 1, c2y: 1)
    /// v4's `glide`; the panel-open and overlay timelines keep it.
    static let out = Easing(c1x: 0.2, c1y: 0, c2x: 0, c2y: 1)
    /// v4's `out` (0, 0, .2, 1): the v5 panel tweens.
    static let decelerate = Easing(c1x: 0, c1y: 0, c2x: 0.2, c2y: 1)
    static let `in` = Easing(c1x: 0.4, c1y: 0, c2x: 1, c2y: 1)

    /// The same curve for SwiftUI.
    func animation(duration: TimeInterval) -> Animation {
        self == .linear ? .linear(duration: duration) : .timingCurve(c1x, c1y, c2x, c2y, duration: duration)
    }

    var caFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(c1x), Float(c1y), Float(c2x), Float(c2y))
    }

    /// Eased progress for linear progress `x` in 0...1 (bisection on the x curve).
    func value(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        if self == .linear { return x }
        func bezier(_ u: Double, _ a: Double, _ b: Double) -> Double {
            let v = 1 - u
            return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bezier(mid, c1x, c2x) < x { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, c1y, c2y)
    }
}

/// What a timeline animates: opacity and uniform scale.
struct Pose: Equatable, Sendable {
    var opacity: Double
    var scale: Double = 1

    func mixed(with other: Pose, _ f: Double) -> Pose {
        Pose(opacity: opacity + (other.opacity - opacity) * f, scale: scale + (other.scale - scale) * f)
    }
}

/// A pose at a time. `easing` shapes the segment that ends at this keyframe; nil uses the timeline's.
struct Keyframe: Equatable, Sendable {
    var time: TimeInterval
    var pose: Pose
    var easing: Easing?
}

/// A pure animation: `pose(at:)` is the single source of truth. Core Animation gets the same
/// keyframes through `animations()`; the offscreen render tool and tests call `pose(at:)`.
struct Timeline: Equatable, Sendable {
    static let maxLoops = 3

    let keyframes: [Keyframe]
    let duration: TimeInterval
    let easing: Easing
    /// Whole cycles played, 1...3. Infinite loops do not exist.
    let loops: Int
    /// The single frame shown instead of the animation under Reduce Motion, and in docs.
    let explanationTime: TimeInterval

    /// Keyframes are sorted, the first is moved to 0 and the last defines `duration`.
    init(keyframes: [Keyframe], easing: Easing = .out, loops: Int = 1, explanationTime: TimeInterval? = nil) {
        var frames = keyframes.sorted { $0.time < $1.time }
        precondition(frames.count >= 2, "a timeline needs at least two keyframes")
        let start = frames[0].time
        frames = frames.map { Keyframe(time: $0.time - start, pose: $0.pose, easing: $0.easing) }
        self.keyframes = frames
        duration = max(frames[frames.count - 1].time, .leastNonzeroMagnitude)
        self.easing = easing
        self.loops = min(max(loops, 1), Self.maxLoops)
        self.explanationTime = min(max(explanationTime ?? frames[frames.count - 1].time, 0), duration)
    }

    /// Two-keyframe convenience.
    init(from: Pose, to: Pose, duration: TimeInterval, easing: Easing = .out, explanationTime: TimeInterval? = nil) {
        self.init(keyframes: [Keyframe(time: 0, pose: from), Keyframe(time: duration, pose: to)],
                  easing: easing, explanationTime: explanationTime)
    }

    /// The model value after the animation: the last keyframe.
    var resting: Pose { keyframes[keyframes.count - 1].pose }
    var totalDuration: TimeInterval { duration * Double(loops) }

    /// The pose `t` seconds after the start. Clamped: before 0 is the first pose, after the last
    /// loop is `resting`.
    func pose(at t: TimeInterval) -> Pose {
        if t <= 0 { return keyframes[0].pose }
        if t >= totalDuration { return resting }
        let local = t.truncatingRemainder(dividingBy: duration)
        for i in 1..<keyframes.count where local <= keyframes[i].time {
            let a = keyframes[i - 1], b = keyframes[i]
            let span = b.time - a.time
            guard span > 0 else { return b.pose }
            return a.pose.mixed(with: b.pose, (b.easing ?? easing).value((local - a.time) / span))
        }
        return resting
    }

    /// Reduce Motion frame. At the end of a cycle it is the resting pose: in a looping timeline
    /// that instant is also the start of the next cycle.
    var explanationPose: Pose { explanationTime >= duration ? resting : pose(at: explanationTime) }

    enum Property: Sendable { case opacity, scale
        var keyPath: String { self == .opacity ? "opacity" : "transform.scale" }
    }

    /// The properties whose values change across the keyframes.
    var animatedProperties: [Property] {
        var result: [Property] = []
        if Set(keyframes.map(\.pose.opacity)).count > 1 { result.append(.opacity) }
        if Set(keyframes.map(\.pose.scale)).count > 1 { result.append(.scale) }
        return result
    }

    /// One `CAKeyframeAnimation` for `property` built from the same keyframes: normalized
    /// keyTimes, per-segment timing functions, removed on completion, no fill.
    func animation(for property: Property) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: property.keyPath)
        animation.values = keyframes.map { property == .opacity ? $0.pose.opacity : $0.pose.scale }
        animation.keyTimes = keyframes.map { NSNumber(value: $0.time / duration) }
        animation.timingFunctions = keyframes.dropFirst().map { ($0.easing ?? easing).caFunction }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.repeatCount = Float(loops)
        animation.isRemovedOnCompletion = true
        animation.fillMode = .removed
        return animation
    }

    func animations() -> [CAKeyframeAnimation] { animatedProperties.map(animation(for:)) }

    /// Sets the model to the resting pose, then adds the animations. Under Reduce Motion, or when
    /// `animated` is false, the model alone is set (to the explanation pose under Reduce Motion).
    @MainActor
    func run(on layer: CALayer, key: String, animated: Bool) {
        layer.removeAnimation(forKey: key + ".opacity")
        layer.removeAnimation(forKey: key + ".scale")
        let animate = animated && !AnimationGate.reduceMotion
        let end = animated && AnimationGate.reduceMotion ? explanationPose : resting
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = Float(end.opacity)
        layer.transform = CATransform3DMakeScale(end.scale, end.scale, 1)
        CATransaction.commit()
        guard animate else { return }
        for property in animatedProperties {
            layer.add(animation(for: property), forKey: key + (property == .opacity ? ".opacity" : ".scale"))
        }
    }
}

extension Pose {
    /// The pose currently on screen, so an interrupting timeline can continue from it.
    @MainActor
    init(presentationOf layer: CALayer) {
        let shown = layer.presentation() ?? layer
        self.init(opacity: Double(shown.opacity), scale: Double(shown.transform.m11))
    }
}

/// Whether anything may animate right now.
enum AnimationGate {
    static func mayAnimate(windowVisible: Bool, occluded: Bool, appHidden: Bool, screensAwake: Bool,
                           reduceMotion: Bool) -> Bool {
        windowVisible && !occluded && !appHidden && screensAwake && !reduceMotion
    }

    @MainActor
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @MainActor
    static var screensAwake: Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        return screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return true }
            return CGDisplayIsAsleep(id) == 0
        }
    }

    /// Live check for `window` (nil = no window, never animate). `reducedForm`: the caller has a
    /// Reduce Motion form of its animation (a short linear fade), so Reduce Motion does not stop it.
    @MainActor
    static func mayAnimate(in window: NSWindow?, reducedForm: Bool = false) -> Bool {
        guard let window else { return false }
        return mayAnimate(windowVisible: window.isVisible && !window.isMiniaturized,
                          occluded: !window.occlusionState.contains(.visible),
                          appHidden: NSApp?.isHidden ?? false,
                          screensAwake: screensAwake,
                          reduceMotion: reducedForm ? false : reduceMotion)
    }
}

/// The named timelines (durations and curves from the v3 motion tokens).
extension Timeline {
    private static let hidden = Pose(opacity: 0, scale: 0.96)
    private static let shown = Pose(opacity: 1)

    static let panelOpen = Timeline(from: Pose(opacity: 0, scale: 0.98), to: shown, duration: 0.16, easing: .out)
    /// Reduce Motion: the panel still fades in, 150 ms linear, without the scale (v5 §6).
    static let panelOpenReduced = Timeline(from: Pose(opacity: 0), to: shown, duration: 0.15, easing: .linear)
    static let cardIn = Timeline(from: hidden, to: shown, duration: 0.18, easing: .out)
    static let cardOut = Timeline(from: shown, to: Pose(opacity: 0), duration: 0.16, easing: .in)
    /// One dot of the Fuse going out: its fill fades; the outline underneath stays.
    static let fuseTick = Timeline(from: shown, to: Pose(opacity: 0), duration: 0.12, easing: .out)
    /// `Kept` / `Reverted`: hold 700 ms, then fade 160 ms. Explanation frame is the hold.
    static let resolved = Timeline(
        keyframes: [Keyframe(time: 0, pose: shown), Keyframe(time: 0.7, pose: shown, easing: .linear),
                    Keyframe(time: 0.86, pose: Pose(opacity: 0), easing: .in)],
        explanationTime: 0)
    /// Fade in 120 ms, hold to 1320 ms, fade out by 1560 ms.
    static let identify = Timeline(
        keyframes: [Keyframe(time: 0, pose: Pose(opacity: 0)), Keyframe(time: 0.12, pose: shown, easing: .out),
                    Keyframe(time: 1.32, pose: shown, easing: .linear),
                    Keyframe(time: 1.56, pose: Pose(opacity: 0), easing: .in)],
        explanationTime: 0.72)
    static let osdShow = Timeline(from: Pose(opacity: 0), to: shown, duration: 0.1, easing: .out)
    static let osdHide = Timeline(from: shown, to: Pose(opacity: 0), duration: 0.25, easing: .in)
    static let rescueIn = cardIn
    static let rescueOut = Timeline(from: shown, to: Pose(opacity: 0), duration: 0.16, easing: .in)
}

/// One value of a panel view moving once from where it is to where the model now says (v5 §6):
/// the fill of a slider, the wash of a chip, a notice tile coming in. Pure like `Timeline`:
/// `progress(at:)` is the curve the SwiftUI animation follows (same control points, same
/// duration), there is no loop and no delay, and the view's state is the rest pose from the first
/// frame, so nothing is left behind when the animation is removed.
struct Tween: Equatable, Sendable {
    let duration: TimeInterval
    let easing: Easing
    /// Reduce Motion: a linear opacity fade of this length (the height snaps), or nil to snap.
    let reducedFade: TimeInterval?

    /// Eased progress `t` seconds after the change: 0 before, 1 (rest) at and after the end.
    func progress(at t: TimeInterval) -> Double {
        t <= 0 ? 0 : t >= duration ? 1 : easing.value(t / duration)
    }

    func value(from start: Double, to end: Double, at t: TimeInterval) -> Double {
        start + (end - start) * progress(at: t)
    }

    /// Reduce Motion shows the change at rest: the explanation frame is the end.
    var explanationProgress: Double { 1 }

    /// The SwiftUI animation for this change; nil snaps. `visible` is false while the panel is
    /// closed: nothing plays hidden.
    func animation(reduceMotion: Bool, visible: Bool = true) -> Animation? {
        guard visible else { return nil }
        if reduceMotion { return reducedFade.map { Easing.linear.animation(duration: $0) } }
        return easing.animation(duration: duration)
    }
}

extension Tween {
    /// Slider fill to a level set from outside the drag (keys, OSD, Undo, wake restore, a probe).
    /// A drag moves the fill immediately.
    static let sliderFill = Tween(duration: 0.16, easing: .decelerate, reducedFade: nil)
    /// Ink and wash under the pointer; pressed is immediate.
    static let hover = Tween(duration: 0.12, easing: .decelerate, reducedFade: nil)
    /// A notice tile: opacity 0 → 1 and height 0 → its own, the modules move with it.
    static let noticeIn = Tween(duration: 0.18, easing: .decelerate, reducedFade: 0.15)
    static let noticeOut = Tween(duration: 0.16, easing: .in, reducedFade: 0.15)
    /// Module content 1 → .45 while a change waits for Keep or the displays wake, and back.
    static let lock = Tween(duration: 0.16, easing: .decelerate, reducedFade: nil)

    static let all: [Tween] = [.sliderFill, .hover, .noticeIn, .noticeOut, .lock]
}

/// Accessibility switches. Animation lives in `Timeline`.
enum Motion {

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
}
