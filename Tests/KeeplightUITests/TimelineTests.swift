import AppKit
import QuartzCore
import Testing
@testable import KeeplightUI

private let line = Timeline(
    keyframes: [Keyframe(time: 0, pose: Pose(opacity: 0, scale: 0.9), easing: nil),
                Keyframe(time: 1, pose: Pose(opacity: 1, scale: 1), easing: .linear),
                Keyframe(time: 2, pose: Pose(opacity: 0.5, scale: 1), easing: .linear)],
    easing: .out, loops: 1, explanationTime: 1)

@Suite struct TimelineTests {
    @Test func poseAtKeyframes() {
        #expect(line.pose(at: 0) == Pose(opacity: 0, scale: 0.9))
        #expect(line.pose(at: 1) == Pose(opacity: 1, scale: 1))
        #expect(line.pose(at: 2) == Pose(opacity: 0.5, scale: 1))
    }

    @Test func linearMidpoints() {
        #expect(abs(line.pose(at: 0.5).opacity - 0.5) < 1e-9)
        #expect(abs(line.pose(at: 0.5).scale - 0.95) < 1e-9)
        #expect(abs(line.pose(at: 1.5).opacity - 0.75) < 1e-9)
    }

    @Test func easedMidpointIsAheadOfLinear() {
        let t = Timeline(from: Pose(opacity: 0), to: Pose(opacity: 1), duration: 1, easing: .out)
        #expect(t.pose(at: 0.5).opacity > 0.5)
        let i = Timeline(from: Pose(opacity: 0), to: Pose(opacity: 1), duration: 1, easing: .in)
        #expect(i.pose(at: 0.5).opacity < 0.5)
    }

    @Test func clamping() {
        #expect(line.pose(at: -3) == line.pose(at: 0))
        #expect(line.pose(at: 99) == line.resting)
        #expect(line.resting == Pose(opacity: 0.5, scale: 1))
    }

    @Test func loopsAreCappedAtThree() {
        let frames = line.keyframes
        #expect(Timeline(keyframes: frames, loops: 50).loops == 3)
        #expect(Timeline(keyframes: frames, loops: 0).loops == 1)
        let looped = Timeline(keyframes: frames, loops: 3)
        #expect(looped.pose(at: 2.5) == line.pose(at: 0.5))
        #expect(looped.pose(at: 6) == looped.resting)
        #expect(looped.animation(for: .opacity).repeatCount == 3)
        #expect(Timeline(keyframes: frames, loops: 50).animation(for: .opacity).repeatCount == 3)
    }

    @Test func explanationFrame() {
        #expect(line.explanationPose == Pose(opacity: 1, scale: 1))
        #expect(Timeline.resolved.explanationPose.opacity == 1)
        #expect(Timeline.identify.explanationPose.opacity == 1)
        #expect(Timeline.cardIn.explanationPose == Pose(opacity: 1))
        let clamped = Timeline(keyframes: line.keyframes, explanationTime: 40)
        #expect(clamped.explanationTime == 2)
    }

    @Test func caAnimationMatchesKeyframes() {
        let animation = line.animation(for: .opacity)
        #expect(animation.keyPath == "opacity")
        #expect((animation.values as? [Double]) == [0, 1, 0.5])
        #expect(animation.keyTimes?.map(\.doubleValue) == [0, 0.5, 1])
        #expect(animation.duration == 2)
        #expect(animation.timingFunctions?.count == 2)
        #expect(animation.isRemovedOnCompletion)
        #expect(animation.fillMode == .removed)
        let scale = line.animation(for: .scale)
        #expect(scale.keyPath == "transform.scale")
        #expect((scale.values as? [Double]) == [0.9, 1, 1])
        #expect(line.animatedProperties == [.opacity, .scale])
    }

    @Test func namedTimelinesAreWellFormed() {
        let all: [Timeline] = [.panelOpen, .cardIn, .cardOut, .fuseTick, .resolved, .identify, .osdShow,
                               .osdHide, .rescueIn, .rescueOut]
        for timeline in all {
            #expect(timeline.loops <= 3)
            #expect(timeline.keyframes.first?.time == 0)
            for animation in timeline.animations() {
                #expect(animation.isRemovedOnCompletion)
                #expect(animation.keyTimes?.first == 0 && animation.keyTimes?.last == 1)
            }
        }
        #expect(abs(Timeline.identify.duration - 1.56) < 1e-9)
        #expect(abs(Timeline.resolved.duration - 0.86) < 1e-9)
        #expect(Timeline.identify.pose(at: 0.12).opacity == 1)
        #expect(Timeline.identify.pose(at: 1.32).opacity == 1)
        #expect(Timeline.identify.pose(at: 1.56).opacity == 0)
    }

    @MainActor
    @Test func runSetsRestingModelAndRemovesNothingForever() {
        let layer = CALayer()
        layer.opacity = 0
        Timeline.cardIn.run(on: layer, key: "t", animated: true)
        #expect(layer.opacity == 1)
        #expect(layer.animation(forKey: "t.opacity")?.isRemovedOnCompletion == true)
        Timeline.cardOut.run(on: layer, key: "t", animated: false)
        #expect(layer.opacity == 0)
        #expect(layer.animation(forKey: "t.opacity") == nil)
    }
}

@Suite struct GateAndFuseTests {
    @Test func gate() {
        #expect(AnimationGate.mayAnimate(windowVisible: true, occluded: false, appHidden: false, screensAwake: true, reduceMotion: false))
        #expect(!AnimationGate.mayAnimate(windowVisible: false, occluded: false, appHidden: false, screensAwake: true, reduceMotion: false))
        #expect(!AnimationGate.mayAnimate(windowVisible: true, occluded: true, appHidden: false, screensAwake: true, reduceMotion: false))
        #expect(!AnimationGate.mayAnimate(windowVisible: true, occluded: false, appHidden: true, screensAwake: true, reduceMotion: false))
        #expect(!AnimationGate.mayAnimate(windowVisible: true, occluded: false, appHidden: false, screensAwake: false, reduceMotion: false))
        #expect(!AnimationGate.mayAnimate(windowVisible: true, occluded: false, appHidden: false, screensAwake: true, reduceMotion: true))
    }

    @Test func fuseClock() {
        #expect(FuseClock.lit(elapsed: 0, total: 15) == 15)
        #expect(FuseClock.lit(elapsed: 0.5, total: 15) == 15)
        #expect(FuseClock.lit(elapsed: 1.5, total: 15) == 14)
        #expect(FuseClock.lit(elapsed: 14.5, total: 15) == 1)
        #expect(FuseClock.lit(elapsed: 15, total: 15) == 0)
        #expect(FuseClock.lit(elapsed: 40, total: 15) == 0)
        #expect(FuseClock.flipTime(index: 14, total: 15) == 1)
        #expect(FuseClock.flipTime(index: 0, total: 15) == 15)
    }

    @MainActor @Test func fuseLabel() {
        #expect(Fuse.label(lit: 10, count: 15) == "10 of 15 dots lit")
    }

    @MainActor
    @Test func fuseLayersFollowLit() {
        let view = FuseLayerView(count: 15, lit: 15)
        view.set(lit: 10, animated: false)
        let fills = view.layer?.sublayers?.enumerated().filter { $0.offset % 2 == 1 }.map(\.element) ?? []
        #expect(fills.count == 15)
        #expect(fills.map(\.opacity) == (0..<15).map { $0 < 10 ? 1 : 0 })
        #expect(view.intrinsicContentSize.width == 260)
    }
}
