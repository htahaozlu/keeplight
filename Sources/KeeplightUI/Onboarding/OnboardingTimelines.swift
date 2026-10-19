import AppKit
import QuartzCore

/// Onboarding motion that is not a scene: the page transition and page 3's state changes. Pure
/// timelines; the window plays them, the render tool draws them.
enum OnboardingTimelines {
    private static func s(_ v: Double) -> SceneValue { .scalar(v) }

    // MARK: page transition (320 ms)

    enum PageID {
        static let oldPage: LayerID = "d.oldPage", newPage: LayerID = "d.newPage"
        static let oldScene: LayerID = "d.oldScene", newScene: LayerID = "d.newScene"
    }

    /// Old text and stage content leave (0–160, `in`, 24 pt), the new ones enter (80–320, `out`,
    /// from 24 pt, the scene from .98); the stage frame itself never moves. The next progress
    /// segment turns ink (0–240, `glide`). Back mirrors the direction. Reduce Motion: 150 ms linear
    /// cross-fades, the progress jumps.
    static func page(forward: Bool, progress: [LayerID: (from: CGColor, to: CGColor)], reduceMotion rm: Bool) -> SceneTimeline {
        typealias ID = PageID
        var base = ScenePose()
        base[ID.oldPage, SceneKeyPath.opacity] = s(0)
        base[ID.newPage, SceneKeyPath.opacity] = s(1)
        base[ID.oldScene, SceneKeyPath.opacity] = s(0)
        base[ID.newScene, SceneKeyPath.opacity] = s(1)
        base[ID.newScene, "transform.scale"] = s(1)
        base[ID.oldPage, "transform.translation.x"] = s(0)
        base[ID.newPage, "transform.translation.x"] = s(0)
        for (id, c) in progress { base[id, "backgroundColor"] = .color(c.to) }
        if rm {
            let d = OnboardingTheme.Motion.reduced
            return SceneTimeline(name: "onb.page", duration: d, explainT: d / 2, base: base, tracks: [
                SceneTrack(ID.oldPage, SceneKeyPath.opacity, [SceneKey(0, s(1)), SceneKey(d, s(0))]),
                SceneTrack(ID.newPage, SceneKeyPath.opacity, [SceneKey(0, s(0)), SceneKey(d, s(1))]),
                SceneTrack(ID.oldScene, SceneKeyPath.opacity, [SceneKey(0, s(1)), SceneKey(d, s(0))]),
                SceneTrack(ID.newScene, SceneKeyPath.opacity, [SceneKey(0, s(0)), SceneKey(d, s(1))]),
            ])
        }
        let shift = forward ? 24.0 : -24.0
        var tracks = [
            SceneTrack(ID.oldPage, SceneKeyPath.opacity, [SceneKey(0, s(1), .in), SceneKey(160, s(0))]),
            SceneTrack(ID.oldPage, "transform.translation.x", [SceneKey(0, s(0), .in), SceneKey(160, s(-shift))]),
            SceneTrack(ID.oldScene, SceneKeyPath.opacity, [SceneKey(0, s(1), .in), SceneKey(160, s(0))]),
            SceneTrack(ID.newPage, SceneKeyPath.opacity, [SceneKey(80, s(0), .out), SceneKey(320, s(1))]),
            SceneTrack(ID.newPage, "transform.translation.x", [SceneKey(80, s(shift), .out), SceneKey(320, s(0))]),
            SceneTrack(ID.newScene, SceneKeyPath.opacity, [SceneKey(80, s(0), .out), SceneKey(320, s(1))]),
            SceneTrack(ID.newScene, "transform.scale", [SceneKey(80, s(0.98), .out), SceneKey(320, s(1))]),
        ]
        for (id, c) in progress.sorted(by: { $0.key < $1.key }) where c.from != c.to {
            tracks.append(SceneTrack(id, "backgroundColor", [SceneKey(0, .color(c.from), .glide), SceneKey(240, .color(c.to))]))
        }
        return SceneTimeline(name: "onb.page", duration: OnboardingTheme.Motion.page, explainT: 160, base: base, tracks: tracks)
    }

    // MARK: page 3 state changes

    enum SceneSwapID {
        static let old: LayerID = "s.old", new: LayerID = "s.new"
    }

    /// One scene hands over to another inside the stage (Keys → Access when `Allow…` is pressed):
    /// out 0–160 `in`, in 80–320 `out` from .98. Reduce Motion: 150 ms linear cross-fade.
    static func sceneSwap(reduceMotion rm: Bool) -> SceneTimeline {
        typealias ID = SceneSwapID
        var base = ScenePose()
        base[ID.old, SceneKeyPath.opacity] = s(0)
        base[ID.new, SceneKeyPath.opacity] = s(1)
        base[ID.new, "transform.scale"] = s(1)
        if rm {
            let d = OnboardingTheme.Motion.reduced
            return SceneTimeline(name: "onb.swap", duration: d, base: base, tracks: [
                SceneTrack(ID.old, SceneKeyPath.opacity, [SceneKey(0, s(1)), SceneKey(d, s(0))]),
                SceneTrack(ID.new, SceneKeyPath.opacity, [SceneKey(0, s(0)), SceneKey(d, s(1))]),
            ])
        }
        return SceneTimeline(name: "onb.swap", duration: 320, base: base, tracks: [
            SceneTrack(ID.old, SceneKeyPath.opacity, [SceneKey(0, s(1), .in), SceneKey(160, s(0))]),
            SceneTrack(ID.new, SceneKeyPath.opacity, [SceneKey(80, s(0), .out), SceneKey(320, s(1))]),
            SceneTrack(ID.new, "transform.scale", [SceneKey(80, s(0.98), .out), SceneKey(320, s(1))]),
        ])
    }

    /// Page 3's row: notAsked → waiting cross-fades the callout into ○ `Waiting…` (0–160 / 80–240);
    /// waiting → granted fills the ring to ink (0–100, `land`), then `Waiting…` and `Not working?`
    /// give way to `Brightness keys are on.` (out 60–160, in 120–280). Reduce Motion: 150 ms linear
    /// cross-fades, the ring filled at once.
    static func keysState(from old: KeysPage.Shown, to new: KeysPage.Shown, reduceMotion rm: Bool) -> SceneTimeline {
        typealias ID = KeysPage.ID
        var base = ScenePose()
        for id in [ID.ask, ID.waitRow, ID.ring, ID.waitText, ID.onText, ID.help] { base[id, SceneKeyPath.opacity] = s(1) }
        base[ID.fill, SceneKeyPath.opacity] = s(new == .granted ? 1 : 0)
        base[ID.fill, "transform.scale"] = s(1)
        let d = OnboardingTheme.Motion.reduced
        switch (old, new) {
        case (.notAsked, .waiting), (.notAsked, .granted):
            base[ID.ask, SceneKeyPath.opacity] = s(0)
            if rm {
                return SceneTimeline(name: "onb.ask", duration: d, base: base, tracks: [
                    SceneTrack(ID.ask, SceneKeyPath.opacity, [SceneKey(0, s(1)), SceneKey(d, s(0))]),
                    SceneTrack(ID.waitRow, SceneKeyPath.opacity, [SceneKey(0, s(0)), SceneKey(d, s(1))]),
                ])
            }
            return SceneTimeline(name: "onb.ask", duration: 240, base: base, tracks: [
                SceneTrack(ID.ask, SceneKeyPath.opacity, [SceneKey(0, s(1), .in), SceneKey(160, s(0))]),
                SceneTrack(ID.waitRow, SceneKeyPath.opacity, [SceneKey(80, s(0), .out), SceneKey(240, s(1))]),
                SceneTrack(ID.help, SceneKeyPath.opacity, [SceneKey(80, s(0), .out), SceneKey(240, s(1))]),
            ])
        case (.waiting, .granted):
            base[ID.waitText, SceneKeyPath.opacity] = s(0)
            base[ID.help, SceneKeyPath.opacity] = s(0)
            if rm {
                return SceneTimeline(name: "onb.grant", duration: d, base: base, tracks: [
                    SceneTrack(ID.waitText, SceneKeyPath.opacity, [SceneKey(0, s(1)), SceneKey(d, s(0))]),
                    SceneTrack(ID.help, SceneKeyPath.opacity, [SceneKey(0, s(1)), SceneKey(d, s(0))]),
                    SceneTrack(ID.onText, SceneKeyPath.opacity, [SceneKey(0, s(0)), SceneKey(d, s(1))]),
                ])
            }
            return SceneTimeline(name: "onb.grant", duration: 280, base: base, tracks: [
                SceneTrack(ID.fill, SceneKeyPath.opacity, [SceneKey(0, s(0), .step), SceneKey(1, s(1))]),
                SceneTrack(ID.fill, "transform.scale", [SceneKey(0, s(0.2), .land), SceneKey(100, s(1))]),
                SceneTrack(ID.waitText, SceneKeyPath.opacity, [SceneKey(60, s(1), .in), SceneKey(160, s(0))]),
                SceneTrack(ID.help, SceneKeyPath.opacity, [SceneKey(0, s(1), .in), SceneKey(160, s(0))]),
                SceneTrack(ID.onText, SceneKeyPath.opacity, [SceneKey(120, s(0), .out), SceneKey(280, s(1))]),
            ])
        default:
            // Back to the question (keys deferred and asked again): a plain cross-fade.
            base[ID.waitRow, SceneKeyPath.opacity] = s(0)
            return SceneTimeline(name: "onb.state", duration: d, base: base, tracks: [
                SceneTrack(ID.waitRow, SceneKeyPath.opacity, [SceneKey(0, s(1)), SceneKey(d, s(0))]),
                SceneTrack(ID.ask, SceneKeyPath.opacity, [SceneKey(0, s(0)), SceneKey(d, s(1))]),
            ])
        }
    }
}
