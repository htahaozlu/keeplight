import Foundation
import QuartzCore

/// Multi-track scene timelines for the onboarding stage (docs/design/v4-keeplight.md §1 Engine;
/// ported from Nokta's `Timeline`). The opacity/scale `Timeline` in `Motion.swift` keeps driving the
/// panel and the overlays; this one moves named layers along any key path.
///
/// The motion contract (docs/DESIGN.md):
///   1. one source — `pose(at:)` and the Core Animation keyframes come from the same keys (a track
///      becomes one `CAKeyframeAnimation`: `values`, `keyTimes` = t / duration, one timing function
///      per segment, `.discrete` when every moving segment is `step`);
///   2. animations are added once, inside one CATransaction; no timers or display links;
///   3. the model stays at the rest pose (`restT`); animations are removed on completion and never
///      fill forwards;
///   4. loops are finite (≤ `SceneTimeline.maxLoops`): a repeated group plus one tail group 0 → `restT`;
///   5. interruptions are new timelines made with `move(from:to:)` from presentation values.
///
/// Times are milliseconds from the start of the timeline.
typealias LayerID = String

// MARK: - easing

/// The v4 curves (§1), identical to `CAMediaTimingFunction(controlPoints:)`.
enum SceneEase: Equatable, Sendable {
    case linear, out, `in`, glide, land, hand, step

    /// (x1, y1, x2, y2); nil for `linear` and `step`.
    var controlPoints: (Double, Double, Double, Double)? {
        switch self {
        case .linear, .step: nil
        case .out: (0, 0, 0.2, 1)
        case .in: (0.4, 0, 1, 1)
        case .glide: (0.2, 0, 0, 1)
        case .land: (0.34, 1.32, 0.64, 1)
        case .hand: (0.42, 0, 0.58, 1)
        }
    }

    /// Eased progress for linear progress `x` in 0…1 (`land` overshoots). `step` holds 0 until the
    /// segment ends.
    func y(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        switch self {
        case .linear: return x
        case .step: return x >= 1 ? 1 : 0
        default:
            guard let (x1, y1, x2, y2) = controlPoints else { return x }
            if x == 0 || x == 1 { return x }
            return Self.bezier(Self.solve(x, x1, x2), y1, y2)
        }
    }

    var timingFunction: CAMediaTimingFunction {
        guard let (x1, y1, x2, y2) = controlPoints else { return CAMediaTimingFunction(name: .linear) }
        return CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }

    static func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private static func derivative(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }

    /// Curve parameter with x(t) = x: Newton, then bisection as fallback.
    static func solve(_ x: Double, _ x1: Double, _ x2: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let err = bezier(t, x1, x2) - x
            if abs(err) < 1e-6 { return t }
            let d = derivative(t, x1, x2)
            if abs(d) < 1e-6 { break }
            let next = t - err / d
            if next < 0 || next > 1 { break }
            t = next
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<64 {
            let v = bezier(t, x1, x2)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return t
    }
}

// MARK: - values

/// One animatable value; `caValue` is what `setValue(_:forKeyPath:)` and keyframe `values` take.
enum SceneValue: Equatable {
    case scalar(Double)
    case point(CGPoint)
    case rect(CGRect)
    case color(CGColor)
    /// Interpolated element by element, like Core Animation does; differing structures step.
    case path(CGPath)

    var caValue: Any {
        switch self {
        case .scalar(let v): NSNumber(value: v)
        case .point(let p): NSValue(point: p)
        case .rect(let r): NSValue(rect: r)
        case .color(let c): c
        case .path(let p): p
        }
    }

    /// A value read back from KVC (presentation values), typed like `template`.
    static func from(_ any: Any?, like template: SceneValue) -> SceneValue? {
        guard let any else { return nil }
        switch template {
        case .scalar: return (any as? NSNumber).map { .scalar($0.doubleValue) }
        case .point: return (any as? NSValue).map { .point($0.pointValue) }
        case .rect: return (any as? NSValue).map { .rect($0.rectValue) }
        case .color:
            guard CFGetTypeID(any as CFTypeRef) == CGColor.typeID else { return nil }
            return .color(any as! CGColor) // type checked above
        case .path:
            guard CFGetTypeID(any as CFTypeRef) == CGPath.typeID else { return nil }
            return .path(any as! CGPath) // type checked above
        }
    }

    var scalarValue: Double? { if case .scalar(let v) = self { return v }; return nil }

    /// a → b at fraction f (f may leave 0…1 for overshooting curves).
    static func lerp(_ a: SceneValue, _ b: SceneValue, _ f: Double) -> SceneValue {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(f) }
        switch (a, b) {
        case let (.scalar(x), .scalar(y)): return .scalar(x + (y - x) * f)
        case let (.point(p), .point(q)): return .point(CGPoint(x: mix(p.x, q.x), y: mix(p.y, q.y)))
        case let (.rect(p), .rect(q)):
            return .rect(CGRect(x: mix(p.minX, q.minX), y: mix(p.minY, q.minY),
                                width: mix(p.width, q.width), height: mix(p.height, q.height)))
        case let (.color(p), .color(q)):
            guard let pc = p.components, let qc = q.components, pc.count == qc.count,
                  p.colorSpace?.name == q.colorSpace?.name, let space = p.colorSpace else { return f < 1 ? a : b }
            return CGColor(colorSpace: space, components: zip(pc, qc).map { mix($0, $1) }).map { .color($0) } ?? (f < 1 ? a : b)
        case let (.path(p), .path(q)):
            return ScenePathElements.lerp(p, q, f).map { .path($0) } ?? (f < 1 ? a : b)
        default:
            return f < 1 ? a : b
        }
    }
}

/// CGPath as a flat element list, for Core Animation's element-wise interpolation.
enum ScenePathElements {
    struct Element: Equatable {
        var type: CGPathElementType
        var points: [CGPoint]
    }

    static func elements(_ path: CGPath) -> [Element] {
        var out: [Element] = []
        path.applyWithBlock { e in
            let el = e.pointee
            let n = switch el.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            default: 0
            }
            out.append(Element(type: el.type, points: (0..<n).map { el.points[$0] }))
        }
        return out
    }

    static func path(_ elements: [Element]) -> CGPath {
        let p = CGMutablePath()
        for e in elements {
            switch e.type {
            case .moveToPoint: p.move(to: e.points[0])
            case .addLineToPoint: p.addLine(to: e.points[0])
            case .addQuadCurveToPoint: p.addQuadCurve(to: e.points[1], control: e.points[0])
            case .addCurveToPoint: p.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
            case .closeSubpath: p.closeSubpath()
            @unknown default: break
            }
        }
        return p
    }

    /// Element-wise interpolation; nil when the structures differ.
    static func lerp(_ a: CGPath, _ b: CGPath, _ f: Double) -> CGPath? {
        let ea = elements(a), eb = elements(b)
        guard ea.count == eb.count, zip(ea, eb).allSatisfy({ $0.type == $1.type }) else { return nil }
        let k = CGFloat(f)
        return path(zip(ea, eb).map { x, y in
            Element(type: x.type, points: zip(x.points, y.points).map { p, q in
                CGPoint(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k)
            })
        })
    }
}

// MARK: - pose

struct ScenePoseKey: Hashable, Sendable {
    let layer: LayerID
    let keyPath: String
    init(_ layer: LayerID, _ keyPath: String) { self.layer = layer; self.keyPath = keyPath }
}

/// A complete or partial picture: a value per (layer, key path).
struct ScenePose: Equatable {
    var values: [ScenePoseKey: SceneValue] = [:]

    subscript(layer: LayerID, keyPath: String) -> SceneValue? {
        get { values[ScenePoseKey(layer, keyPath)] }
        set { values[ScenePoseKey(layer, keyPath)] = newValue }
    }

    /// `other` wins where both have a key.
    func merging(_ other: ScenePose) -> ScenePose {
        var p = self
        p.values.merge(other.values) { _, new in new }
        return p
    }

    var keys: Set<ScenePoseKey> { Set(values.keys) }
}

// MARK: - timeline

/// `value` at `t` (ms); `ease` shapes the segment towards the next key.
struct SceneKey: Equatable {
    let t: Double
    let value: SceneValue
    let ease: SceneEase
    init(_ t: Double, _ value: SceneValue, _ ease: SceneEase = .linear) {
        self.t = t; self.value = value; self.ease = ease
    }
}

struct SceneTrack: Equatable {
    let layer: LayerID
    let keyPath: String
    /// Sorted by `t`.
    let keys: [SceneKey]

    init(_ layer: LayerID, _ keyPath: String, _ keys: [SceneKey]) {
        self.layer = layer
        self.keyPath = keyPath
        self.keys = keys.sorted { $0.t < $1.t }
    }

    /// Holds the first value before the first key and the last value after the last key.
    func value(at t: Double) -> SceneValue {
        guard let first = keys.first, let last = keys.last else { return .scalar(0) }
        if t <= first.t { return first.value }
        if t >= last.t { return last.value }
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            guard t >= a.t, t < b.t else { continue }
            let span = b.t - a.t
            guard span > 0 else { return b.value }
            return SceneValue.lerp(a.value, b.value, a.ease.y((t - a.t) / span))
        }
        return last.value
    }

    /// Whether any key differs from the first (a still track adds no animation).
    var moves: Bool { keys.contains { $0.value != keys.first?.value } }
}

/// A pure description of one scene or transition.
struct SceneTimeline {
    /// The contract's loop cap: a scene plays at most this many cycles, then its tail.
    static let maxLoops = 3

    let name: String
    /// ms.
    let duration: Double
    /// The pose the model is left in (applied before playing; the animations end there).
    let restT: Double
    /// Reduce Motion / static picture: a pose that reads on its own.
    let explainT: Double
    /// Values that do not move; `tracks` override them.
    var base: ScenePose
    var tracks: [SceneTrack]

    init(name: String, duration: Double, restT: Double? = nil, explainT: Double? = nil,
         base: ScenePose = ScenePose(), tracks: [SceneTrack] = []) {
        self.name = name
        self.duration = duration
        self.restT = restT ?? duration
        self.explainT = explainT ?? (restT ?? duration)
        self.base = base
        self.tracks = tracks
    }

    /// Pure: the same t always gives the same pose.
    func pose(at t: Double) -> ScenePose {
        var p = base
        for track in tracks { p[track.layer, track.keyPath] = track.value(at: t) }
        return p
    }

    var restPose: ScenePose { pose(at: restT) }
    var explainPose: ScenePose { pose(at: explainT) }

    /// Every (layer, key path) this timeline sets.
    var keys: Set<ScenePoseKey> { base.keys.union(tracks.map { ScenePoseKey($0.layer, $0.keyPath) }) }

    // MARK: Core Animation

    struct Keyframes {
        var keyTimes: [Double]
        var values: [SceneValue]
        var eases: [SceneEase]
        var discrete: Bool
    }

    /// A track's keys padded to 0…duration. When every moving segment steps the animation is
    /// `.discrete`; in a mixed track a step segment is a held key plus a zero-length jump.
    func keyframes(for track: SceneTrack) -> Keyframes {
        var keys = track.keys
        guard let first = keys.first, let last = keys.last else {
            return Keyframes(keyTimes: [], values: [], eases: [], discrete: false)
        }
        if first.t > 0 { keys.insert(SceneKey(0, first.value), at: 0) }
        if last.t < duration { keys.append(SceneKey(duration, last.value)) }
        let moving = (0..<(keys.count - 1)).filter { keys[$0].value != keys[$0 + 1].value }
        let allStep = !moving.isEmpty && moving.allSatisfy { keys[$0].ease == .step }
        let d = max(duration, 1e-9)
        if allStep {
            return Keyframes(keyTimes: keys.map { min(max($0.t / d, 0), 1) }, values: keys.map(\.value),
                             eases: (0..<(keys.count - 1)).map { _ in .linear }, discrete: true)
        }
        var times: [Double] = [], values: [SceneValue] = [], eases: [SceneEase] = []
        for (i, k) in keys.enumerated() {
            times.append(k.t); values.append(k.value)
            guard i < keys.count - 1 else { break }
            let next = keys[i + 1]
            if k.ease == .step && k.value != next.value {
                times.append(next.t); values.append(k.value) // hold …
                eases.append(.linear)
                eases.append(.linear)                        // … then jump in zero time
            } else {
                eases.append(k.ease)
            }
        }
        return Keyframes(keyTimes: times.map { min(max($0 / d, 0), 1) }, values: values, eases: eases, discrete: false)
    }

    /// One keyframe animation spanning the whole timeline (begin time 0, i.e. relative).
    func keyframeAnimation(for track: SceneTrack) -> CAKeyframeAnimation {
        let k = keyframes(for: track)
        let a = CAKeyframeAnimation(keyPath: track.keyPath)
        a.values = k.values.map(\.caValue)
        a.keyTimes = k.keyTimes.map { NSNumber(value: $0) }
        a.timingFunctions = k.eases.map(\.timingFunction)
        a.calculationMode = k.discrete ? .discrete : .linear
        a.duration = duration / 1000
        a.isRemovedOnCompletion = true
        return a
    }

    struct LayerAnimation {
        let layer: LayerID
        let key: String
        let animation: CAAnimation
    }

    /// A newer timeline moving the same key path replaces the older one.
    static func animationKey(_ keyPath: String) -> String { "scene." + keyPath }

    /// Animations to add inside one CATransaction. `begin` is in the layers' time space. Every
    /// layer's tracks play as one group `loops` times (capped at `maxLoops`), then a tail group
    /// 0 → `restT` brings them to the rest pose; never infinite. No tail (and no group for a single
    /// cycle) when `restT` is 0 or the full duration. Still tracks are skipped (the rest pose
    /// already holds them).
    func animations(begin: CFTimeInterval, loops: Int = 1) -> [LayerAnimation] {
        let loops = min(max(loops, 1), Self.maxLoops)
        let moving = tracks.filter(\.moves)
        let hasTail = restT > 0 && restT < duration
        guard loops > 1 || hasTail else {
            return moving.map { track in
                let a = keyframeAnimation(for: track)
                a.beginTime = begin
                a.fillMode = .backwards // before `begin` show the first key, not the rest pose
                return LayerAnimation(layer: track.layer, key: Self.animationKey(track.keyPath), animation: a)
            }
        }
        var out: [LayerAnimation] = []
        let byLayer = Dictionary(grouping: moving, by: \.layer)
        for layer in byLayer.keys.sorted() {
            let children = byLayer[layer] ?? []
            let loop = CAAnimationGroup()
            loop.animations = children.map { keyframeAnimation(for: $0) }
            loop.duration = duration / 1000
            loop.repeatCount = Float(loops)
            loop.beginTime = begin
            loop.fillMode = .backwards
            loop.isRemovedOnCompletion = true
            out.append(LayerAnimation(layer: layer, key: "scene.loop", animation: loop))
            if hasTail {
                let tail = CAAnimationGroup()
                tail.animations = children.map { keyframeAnimation(for: $0) }
                tail.duration = restT / 1000
                tail.beginTime = begin + Double(loops) * duration / 1000
                tail.isRemovedOnCompletion = true
                out.append(LayerAnimation(layer: layer, key: "scene.tail", animation: tail))
            }
        }
        return out
    }

    // MARK: interruption

    /// From the presentation values `from` to `to` in `duration` ms. Keys only in `to` start at
    /// their target; keys already equal produce no track.
    static func move(name: String, from: ScenePose, to: ScenePose, duration: Double, ease: SceneEase) -> SceneTimeline {
        var tracks: [SceneTrack] = []
        for (key, target) in to.values.sorted(by: { ($0.key.layer, $0.key.keyPath) < ($1.key.layer, $1.key.keyPath) }) {
            guard let start = from.values[key], start != target else { continue }
            tracks.append(SceneTrack(key.layer, key.keyPath, [SceneKey(0, start, ease), SceneKey(duration, target)]))
        }
        return SceneTimeline(name: name, duration: duration, base: to, tracks: tracks)
    }

    // MARK: composition

    /// The same timeline starting `d` ms later (every value holds its first key until then).
    func delayed(by d: Double) -> SceneTimeline {
        SceneTimeline(name: name, duration: duration + d, restT: restT + d, explainT: explainT + d, base: base,
                      tracks: tracks.map { t in SceneTrack(t.layer, t.keyPath, t.keys.map { SceneKey($0.t + d, $0.value, $0.ease) }) })
    }
}

// MARK: - applying

/// Sets poses on named layers and plays timelines; each call is one CATransaction with implicit
/// actions disabled.
@MainActor
enum ScenePlayer {
    static func apply(_ pose: ScenePose, to layers: [LayerID: CALayer]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        set(pose, on: layers)
        CATransaction.commit()
    }

    /// Without a transaction of its own (callers are inside one).
    static func set(_ pose: ScenePose, on layers: [LayerID: CALayer]) {
        for (key, value) in pose.values {
            layers[key.layer]?.setValue(value.caValue, forKeyPath: key.keyPath)
        }
    }

    /// The values currently on screen for the keys of `template` (presentation layer, else model).
    static func presentationPose(like template: ScenePose, in layers: [LayerID: CALayer]) -> ScenePose {
        var p = ScenePose()
        for (key, value) in template.values {
            guard let layer = layers[key.layer] else { continue }
            let source = layer.presentation() ?? layer
            if let v = SceneValue.from(source.value(forKeyPath: key.keyPath), like: value) { p.values[key] = v }
        }
        return p
    }

    /// Rest poses of all `timelines`, then their animations, in one transaction. Demos run at 30…60
    /// Hz, never 120. `completion` runs once every animation added here has finished.
    static func play(_ timelines: [SceneTimeline], on layers: [LayerID: CALayer], loops: Int = 1,
                     completion: (@MainActor () -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let completion { CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } } }
        for t in timelines { set(t.restPose, on: layers) }
        // Layers of one tree share a time space; any of them converts "now".
        let now = layers.values.first.map { $0.convertTime(CACurrentMediaTime(), from: nil) } ?? CACurrentMediaTime()
        for t in timelines {
            for item in t.animations(begin: now, loops: loops) {
                limitFrameRate(item.animation)
                layers[item.layer]?.add(item.animation, forKey: item.key)
            }
        }
        CATransaction.commit()
    }

    private static func limitFrameRate(_ a: CAAnimation) {
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        (a as? CAAnimationGroup)?.animations?.forEach(limitFrameRate)
    }

    /// Removes every animation from `layers` (the gate closed, the page changed).
    static func stop(_ layers: [LayerID: CALayer]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers.values { layer.removeAllAnimations() }
        CATransaction.commit()
    }
}

/// A layer delegate that turns off every implicit animation: scene layers move only through
/// timelines.
final class NoImplicitActions: NSObject, CALayerDelegate {
    nonisolated(unsafe) static let shared = NoImplicitActions()
    func action(for layer: CALayer, forKey event: String) -> (any CAAction)? { NSNull() }
}

/// Key paths the scenes animate.
enum SceneKeyPath {
    static let opacity = "opacity"
    static let position = "position"
    static let bounds = "bounds"
}
