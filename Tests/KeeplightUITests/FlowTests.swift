import AppKit
@testable import DisplayCore
import Testing
@testable import KeeplightUI

/// End-user flows found broken in the v3 product pass: brightness keys, erase, and the reason a
/// display has no brightness control.
@MainActor
@Suite("User flows")
struct FlowTests {
    // MARK: Brightness keys

    @Test func functionKeysAreOptIn() {
        let prefs = Preferences(store: nil, domain: nil)
        #expect(!prefs.brightnessKeys)
        // Turning brightness keys on (first run shows only that toggle) must not take F1/F2 too.
        #expect(!prefs.functionKeysAsBrightness)
        prefs.functionKeysAsBrightness = true
        prefs.eraseAll()
        #expect(!prefs.functionKeysAsBrightness)
    }

    @Test func eraseKeepsTheFunctionKeyCallback() {
        let prefs = Preferences(store: nil, domain: nil)
        var calls = 0
        prefs.onFunctionKeysChange = { calls += 1 }
        prefs.functionKeysAsBrightness = true
        #expect(calls == 1)
        prefs.eraseAll()
        // The reset itself does not call back; the next toggle does.
        #expect(calls == 1)
        prefs.functionKeysAsBrightness = true
        #expect(calls == 2)
    }

    @Test func eraseAllDataStopsTheKeyTap() {
        let rig = Rig()
        rig.keys.isRunning = true
        rig.model.prefs.brightnessKeys = true
        rig.model.brightnessKeysActive = true
        rig.model.eraseAllData()
        #expect(rig.keys.stops >= 1)
        #expect(!rig.keys.isRunning)
        #expect(!rig.model.brightnessKeysActive)
        #expect(!rig.model.prefs.brightnessKeys)
        // Settings' F1/F2 toggle still reaches the tap after the erase.
        let before = rig.keys.functionKeyChanges
        rig.model.prefs.functionKeysAsBrightness.toggle()
        #expect(rig.keys.functionKeyChanges == before + 1)
    }

    @Test func aLateTrustCheckAfterTurningKeysOffStartsNothing() {
        // Re-checks scheduled by the Accessibility notification can land after `stop()`.
        #expect(BrightnessKeys.trustAction(running: false, trusted: true, following: false) == .none)
        #expect(BrightnessKeys.trustAction(running: false, trusted: true, following: true) == .start)
        // A running tap is still dropped when Accessibility goes away.
        #expect(BrightnessKeys.trustAction(running: true, trusted: false, following: false) == .stop)
    }

    // MARK: No brightness control

    private func report(_ facts: DiagnosticFacts) -> DiagnosticReport {
        DiagnosticReport(display: "LG HDR 4K", fingerprint: "GSM:5B9C:…417", steps: [], verdict: "",
                         facts: facts, hardwareModel: facts.hardwareModel, architecture: "arm64",
                         macOS: "26.5", edid: nil, serial: nil, keeplightVersion: "test", generatedAt: Date())
    }

    private func facts(connection: DiagnosticFacts.Connection = .direct, intel: Bool = false,
                       channel: Bool? = true, reply: DiagnosticFacts.DDCReply = .noReply) -> DiagnosticFacts {
        DiagnosticFacts(connection: connection, isIntel: intel, hardwareModel: "Mac15,3", appleBrightness: false,
                        ddcChannel: channel, ddcReply: reply)
    }

    private var external: DisplayInfo {
        DisplayInfo(id: 9, name: "LG HDR 4K", vendorID: 1, productID: 2, serialNumber: 3, uuid: nil,
                    isBuiltin: false, isMain: false, isActive: true, isOnline: true, mirrorSource: nil,
                    bounds: .zero, rotation: 0, currentMode: nil, fingerprint: "GSM:5B9C:417")
    }

    @Test func theNoControlLineFollowsTheDiagnosis() {
        #expect(Copy.noControlLine(report(facts()), display: external) == "Turn on DDC/CI in the monitor's menu.")
        #expect(Copy.noControlLine(report(facts(connection: .virtual)), display: external)
            == "This dock or cable blocks DDC.")
        // Intel: no DDC in Keeplight at all, so the monitor's menu is the wrong advice.
        #expect(Copy.noControlLine(report(facts(intel: true, channel: nil)), display: external)
            == "Intel Macs: no DDC/CI in Keeplight yet.")
        // The monitor answers but exposes no brightness: DDC/CI is already on.
        #expect(Copy.noControlLine(report(facts(reply: .maxZero)), display: external)
            == "This input or picture mode locks brightness.")
        #expect(Copy.noControlLine(nil, display: external) == nil)
    }

    // MARK: Onboarding

    @Test func onboardingShowsUntilItsVersionIsFinished() {
        let rig = Rig(brightness: (.apple, 0.5))
        #expect(rig.model.prefs.onboardingVersion == 0)
        #expect(rig.model.showFirstRun)
        let flow = OnboardingFlow(model: rig.model)
        flow.finish(applyLogin: false)
        #expect(!rig.model.showFirstRun)
        #expect(rig.model.prefs.onboardingVersion == OnboardingFlow.version)
        // Persisted: a later launch reads the finished version back and skips onboarding.
        let suite = "keeplight-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        Preferences(store: defaults, domain: nil).onboardingVersion = OnboardingFlow.version
        #expect(Preferences(store: defaults, domain: nil).onboardingVersion >= OnboardingFlow.version)
        #expect(Preferences(store: UserDefaults(suiteName: suite + ".fresh")!, domain: nil).onboardingVersion < OnboardingFlow.version)
    }

    @Test func debugModeNeverShowsOrWritesOnboarding() {
        let rig = Rig(brightness: (.apple, 0.5), debug: true)
        #expect(!rig.model.showFirstRun)
        // The debug `firstrun` preview may show it; finishing still writes nothing.
        rig.model.showFirstRun = true
        OnboardingFlow(model: rig.model).finish(applyLogin: true)
        #expect(rig.model.prefs.onboardingVersion == 0)
        #expect(rig.login.calls.isEmpty)
    }

    @Test func withoutAMonitorTheKeysCouldDriveThereAreTwoPages() {
        let rig = Rig(brightness: (.apple, 0.5))
        let flow = OnboardingFlow(model: rig.model)
        #expect(flow.steps == [.welcome, .keep])
        #expect(flow.step == .welcome && !flow.isLast)
        flow.advance()
        #expect(flow.step == .keep && flow.isLast && flow.index == 1)
        flow.back()
        #expect(flow.step == .welcome)
        flow.back()
        #expect(flow.step == .welcome)
        flow.advance()
        flow.advance() // Done
        #expect(flow.isFinished && !rig.model.showFirstRun)
        #expect(rig.keys.requests == 0 && !rig.model.prefs.brightnessKeys)
    }

    @Test func aDDCMonitorAddsTheKeysPage() async {
        let rig = Rig(brightness: (.ddc, 0.5))
        #expect(await rig.eventually { rig.hasBrightness })
        let flow = OnboardingFlow(model: rig.model)
        #expect(flow.steps == [.welcome, .keep, .keys])
        #expect(flow.keyableDisplayNames == ["Test Display"])
        #expect(OnboardingCopy.keysLine(names: flow.keyableDisplayNames) == "Use your keyboard's brightness keys on Test Display.")
        #expect(OnboardingCopy.keysLine(names: ["A", "B"]) == "Use your keyboard's brightness keys on your external displays.")
        flow.advance()
        #expect(!flow.isLast)
        flow.advance()
        #expect(flow.step == .keys && flow.isLast && flow.permission == .notAsked)
        // Nothing is asked until `Allow…`.
        #expect(rig.keys.requests == 0)
    }

    @Test func allowWaitsThenTheGrantTurnsTheKeysOn() async {
        let rig = Rig(brightness: (.ddc, 0.5))
        #expect(await rig.eventually { rig.hasBrightness })
        let flow = OnboardingFlow(model: rig.model)
        flow.step = .keys
        flow.allow()
        #expect(flow.permission == .waiting)
        #expect(rig.model.prefs.brightnessKeys && rig.keys.requests == 1)
        // The 1 Hz fallback: only on page 3, only while waiting, only on screen.
        #expect(flow.wantsTrustPolling(onScreen: true))
        #expect(!flow.wantsTrustPolling(onScreen: false))
        flow.step = .keep
        #expect(!flow.wantsTrustPolling(onScreen: true))
        flow.step = .keys
        // A look before the grant changes nothing; a second Allow asks nothing more.
        #expect(!flow.checkTrust())
        flow.allow()
        #expect(flow.permission == .waiting && rig.keys.requests == 1)
        rig.keys.trusted = true
        #expect(flow.checkTrust())
        #expect(flow.permission == .granted && rig.model.brightnessKeysActive)
        #expect(!flow.wantsTrustPolling(onScreen: true))
        // Done ends onboarding; the keys stay on.
        flow.advance()
        #expect(flow.isFinished && rig.model.prefs.brightnessKeys)
    }

    @Test func theEventPathAlsoGrants() async {
        let rig = Rig(brightness: (.ddc, 0.5))
        #expect(await rig.eventually { rig.hasBrightness })
        let flow = OnboardingFlow(model: rig.model)
        flow.step = .keys
        flow.allow()
        // The tap starts by itself (Accessibility broadcast, app active): the flow reads it.
        rig.keys.trusted = true
        rig.keys.verifyTrust()
        #expect(rig.model.brightnessKeysActive)
        #expect(flow.syncPermission() && flow.permission == .granted)
        #expect(!flow.syncPermission())
    }

    @Test func alreadyTrustedIsGrantedAtOnce() async {
        let rig = Rig(brightness: (.ddc, 0.5))
        #expect(await rig.eventually { rig.hasBrightness })
        rig.keys.trusted = true
        let flow = OnboardingFlow(model: rig.model)
        flow.step = .keys
        flow.allow()
        #expect(flow.permission == .granted && rig.keys.requests == 1)
    }

    @Test func notNowAndClosingDeferTheKeys() async {
        let rig = Rig(brightness: (.ddc, 0.5))
        #expect(await rig.eventually { rig.hasBrightness })
        // Not Now before asking: nothing is asked, nothing turned on.
        let first = OnboardingFlow(model: rig.model)
        first.step = .keys
        first.notNow()
        #expect(first.permission == .deferred && first.isFinished)
        #expect(rig.keys.requests == 0 && !rig.model.prefs.brightnessKeys)
        // Not Now while waiting: the keys go off again.
        let second = OnboardingFlow(model: rig.model)
        second.step = .keys
        second.allow()
        second.notNow()
        #expect(second.permission == .deferred && !rig.model.prefs.brightnessKeys && rig.keys.stops >= 1)
        // Closing the window while waiting: the same.
        let third = OnboardingFlow(model: rig.model)
        third.step = .keys
        third.allow()
        third.finish(applyLogin: false)
        #expect(third.permission == .deferred && !rig.model.prefs.brightnessKeys)
        #expect(!third.wantsTrustPolling(onScreen: true))
    }

    @Test func openAtLoginFollowsTheLastPagesAnswer() {
        let rig = Rig(brightness: (.apple, 0.5))
        let done = OnboardingFlow(model: rig.model)
        #expect(done.openAtLogin) // on by default, visible
        done.step = .keep
        done.advance() // Done on the last page
        #expect(rig.login.calls == [true] && rig.model.launchAtLogin)
        // Closing applies nothing, and neither does Done with the switch matching the login item.
        let rig2 = Rig(brightness: (.apple, 0.5))
        let closed = OnboardingFlow(model: rig2.model)
        closed.step = .keep
        closed.finish(applyLogin: false)
        #expect(rig2.login.calls.isEmpty)
        let rig3 = Rig(brightness: (.apple, 0.5))
        let off = OnboardingFlow(model: rig3.model)
        off.openAtLogin = false
        off.step = .keep
        off.advance()
        #expect(rig3.login.calls.isEmpty && !rig3.model.launchAtLogin)
    }

    @Test func launchNeverShowsThePromptByItself() {
        let rig = Rig()
        rig.model.prefs.brightnessKeys = true
        let waits = rig.keys.waits
        rig.model.syncBrightnessKeys()
        rig.model.syncBrightnessKeys()
        #expect(rig.keys.requests == 0)
        #expect(rig.keys.waits > waits)
    }

    // MARK: Migration

    @Test func dotpitchDefaultsComeOverOnceWithoutTheKeysGrant() throws {
        let suite = "keeplight-tests-migration-\(UUID().uuidString)"
        let target = try #require(UserDefaults(suiteName: suite))
        defer { target.removePersistentDomain(forName: suite) }
        let written = LastWritten(value: 0.4, date: Date(timeIntervalSince1970: 1_700_000_000))
        let legacy: [String: Any] = [
            "nicknames": ["DELL:1": "Left"],
            "knownDisplays": ["DELL:1": "DELL U2723QE"],
            "lastWritten": try JSONEncoder().encode(["DELL:1": written]),
            "revertSeconds": 30,
            "restoreAfterWake": false,
            "hasLaunched": true,
            "brightnessKeys": true,
            "functionKeysAsBrightness": true,
        ]
        // Already set in the new domain: never overwritten.
        target.set(["X:1": "Mine"], forKey: "nicknames")
        let imported = DefaultsMigration.importLegacy(legacy, into: target)
        #expect(imported == ["knownDisplays", "lastWritten", "restoreAfterWake", "revertSeconds"])
        for key in ["hasLaunched", "brightnessKeys", "functionKeysAsBrightness", "onboardingVersion"] {
            #expect(target.object(forKey: key) == nil, "\(key) must not come over")
        }
        let prefs = Preferences(store: target, domain: nil)
        #expect(prefs.nicknames == ["X:1": "Mine"])
        #expect(prefs.knownDisplays == ["DELL:1": "DELL U2723QE"])
        #expect(prefs.lastWritten["DELL:1"] == written)
        #expect(prefs.revertSeconds == 30 && !prefs.restoreAfterWake)
        #expect(!prefs.brightnessKeys && !prefs.functionKeysAsBrightness && prefs.onboardingVersion == 0)
        // Second launch: nothing left to import.
        #expect(DefaultsMigration.importLegacy(legacy, into: target).isEmpty)
        #expect(DefaultsMigration.importLegacy(nil, into: target).isEmpty)
    }

    @Test func malformedLegacyValuesAreSkipped() throws {
        let suite = "keeplight-tests-migration-\(UUID().uuidString)"
        let target = try #require(UserDefaults(suiteName: suite))
        defer { target.removePersistentDomain(forName: suite) }
        let legacy: [String: Any] = [
            "nicknames": ["a": 1], "knownDisplays": "nope", "lastWritten": Data("x".utf8),
            "revertSeconds": 99, "restoreAfterWake": "yes",
        ]
        #expect(DefaultsMigration.importLegacy(legacy, into: target).isEmpty)
        #expect(DefaultsMigration.legacyDomain == "io.github.htahaozlu.Dotpitch")
    }

    // MARK: Soft

    @Test func onlyStretchedModesAreSoft() {
        let info = DisplayInfo(id: 3, name: "BenQ EW3270U", vendorID: 1, productID: 2, serialNumber: 3, uuid: nil,
                               isBuiltin: false, isMain: true, isActive: true, isOnline: true, mirrorSource: nil,
                               bounds: .zero, rotation: 0, currentMode: nil, fingerprint: "BNQ:1")
        func mode(_ n: Int32, _ w: Int, _ h: Int, density: Double) -> DisplayMode {
            DisplayMode(modeNumber: n, width: w, height: h, refreshRate: 60, depth: 8, density: density, flags: 0x1)
        }
        let item = DisplayItem(info: info, index: 1, modes: [], native: PixelSize((3840, 2160)), isPhysical: true,
                               isNew: false)
        // A 4K panel: macOS's HiDPI "Looks like" sizes are not blurry.
        #expect(!item.isSoft(mode(1, 1920, 1080, density: 2)))   // crisp
        #expect(!item.isSoft(mode(2, 2560, 1440, density: 2)))   // scaled
        #expect(!item.isSoft(mode(3, 3008, 1692, density: 2)))   // scaled
        #expect(!item.isSoft(mode(4, 3840, 2160, density: 1)))   // native
        #expect(item.isSoft(mode(5, 2560, 1440, density: 1)))    // stretched by the monitor
    }
}

/// The onboarding's scene engine (`SceneTimeline`) and its visibility gate (`MotionGate`).
@MainActor
@Suite("Scene motion")
struct SceneMotionTests {
    private var scenes: [StageScene] { [LightScene(), FuseScene(), KeysScene(), AccessScene()] }

    /// Equal, up to the rounding of keyTime × duration.
    private static func close(_ a: SceneValue, _ b: SceneValue) -> Bool {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)): abs(x - y) < 1e-9
        case let (.point(p), .point(q)): abs(p.x - q.x) < 1e-6 && abs(p.y - q.y) < 1e-6
        case let (.rect(p), .rect(q)): abs(p.width - q.width) < 1e-6 && abs(p.minX - q.minX) < 1e-6
        default: a == b
        }
    }

    @Test func coreAnimationKeyframesComeFromTheSameKeysAsPose() {
        for scene in scenes {
            let timeline = scene.timeline
            for track in timeline.tracks {
                // Every key is what pose(at:) shows at its time.
                for key in track.keys {
                    #expect(timeline.pose(at: key.t)[track.layer, track.keyPath] == key.value,
                            "\(timeline.name) \(track.layer).\(track.keyPath) at \(key.t)")
                }
                guard track.moves else { continue }
                let k = timeline.keyframes(for: track)
                #expect(k.keyTimes.count == k.values.count && k.eases.count == k.values.count - 1)
                #expect(k.keyTimes.first == 0 && k.keyTimes.last == 1)
                #expect(zip(k.keyTimes, k.keyTimes.dropFirst()).allSatisfy { $0 <= $1 })
                // At each distinct key time the keyframe value is the pose (a step's zero-length
                // jump keeps its later value).
                for (i, time) in k.keyTimes.enumerated() where i == k.keyTimes.count - 1 || k.keyTimes[i + 1] != time {
                    #expect(Self.close(track.value(at: time * timeline.duration), k.values[i]),
                            "\(timeline.name) \(track.layer).\(track.keyPath) keyframe \(i)")
                }
                let animation = timeline.keyframeAnimation(for: track)
                #expect(animation.values?.count == k.values.count && animation.isRemovedOnCompletion)
            }
        }
    }

    @Test func loopsAreFiniteAndEndOnTheRestPose() {
        for scene in scenes {
            #expect(scene.loops >= 1 && scene.loops <= SceneTimeline.maxLoops)
            let timeline = scene.timeline
            // Asked for more, the engine still plays at most three cycles, never forever.
            for item in timeline.animations(begin: 0, loops: 10) {
                #expect(item.animation.repeatCount <= Float(SceneTimeline.maxLoops))
                #expect(item.animation.repeatCount != .infinity)
                #expect(item.animation.isRemovedOnCompletion)
                #expect(item.animation.fillMode != .forwards && item.animation.fillMode != .both)
            }
            if scene.loops > 1 {
                // Cycles join without a seam.
                #expect(timeline.pose(at: 0) == timeline.pose(at: timeline.duration), "\(timeline.name) seam")
            }
        }
    }

    @Test func everySceneRestsOnItsExplanationFrame() {
        for scene in scenes {
            let t = scene.timeline
            #expect(t.explainT >= 0 && t.explainT <= t.duration)
            #expect(t.restPose == t.explainPose, "\(t.name)")
        }
        let light = LightScene()
        #expect(light.timeline.explainT == LightScene.duration)
        // The Fuse's frame: 10 of 15 dots lit.
        let fuse = FuseScene().timeline
        #expect(fuse.explainT == 1200 && fuse.duration == 4400)
        let lit = (0..<FuseScene.count).filter { fuse.explainPose[FuseScene.ID.dot($0), "opacity"] == .scalar(1) }
        #expect(lit.count == 10 && lit == Array(0..<10))
        // Keys: the key held down with the OSD up. Access: the switch on.
        let keys = KeysScene().timeline
        #expect(keys.explainT == 400 && keys.explainPose[KeysScene.ID.osd, "opacity"] == .scalar(1))
        #expect(keys.explainPose[KeysScene.ID.cap, "transform.translation.y"] == .scalar(2))
        let access = AccessScene().timeline
        #expect(access.explainT == 1500 && access.explainPose[AccessScene.ID.knob, "position"] == .point(AccessScene.knobOn))
    }

    @Test func welcomeDrawsAtMostThreeDisplaysInTheirOrder() {
        let scene = LightScene()
        let screens = (0..<4).map { LightScene.Screen(name: "D\($0)", bounds: CGRect(x: CGFloat(3 - $0) * 2000, y: 0, width: 1920, height: 1080)) }
        scene.configure(screens)
        #expect(scene.screens.count == 3)
        let frames = LightScene.layout(screens.prefix(3).map(\.bounds))
        // Arrangement order: the rightmost display is drawn rightmost.
        #expect(frames[0].minX > frames[1].minX && frames[1].minX > frames[2].minX)
        #expect(frames.allSatisfy { CGRect(origin: .zero, size: StageScene.size).contains($0) })
        #expect(frames.allSatisfy { $0.size == LightScene.outlineSize })
    }

    @Test func thePageTransitionIsD() {
        let forward = OnboardingTimelines.page(forward: true, progress: [:], reduceMotion: false)
        #expect(forward.duration == 320)
        typealias ID = OnboardingTimelines.PageID
        #expect(forward.pose(at: 160)[ID.oldPage, "opacity"] == .scalar(0))
        #expect(forward.pose(at: 80)[ID.newPage, "transform.translation.x"] == .scalar(24))
        #expect(forward.pose(at: 320)[ID.newScene, "transform.scale"] == .scalar(1))
        let back = OnboardingTimelines.page(forward: false, progress: [:], reduceMotion: false)
        #expect(back.pose(at: 80)[ID.newPage, "transform.translation.x"] == .scalar(-24))
        let reduced = OnboardingTimelines.page(forward: true, progress: [:], reduceMotion: true)
        #expect(reduced.duration == 150)
        #expect(reduced.tracks.allSatisfy { $0.keyPath == "opacity" })
        // The granted ring fills in 100 ms with `land`.
        let grant = OnboardingTimelines.keysState(from: .waiting, to: .granted, reduceMotion: false)
        let fill = grant.tracks.first { $0.layer == KeysPage.ID.fill && $0.keyPath == "transform.scale" }
        #expect(fill?.keys.first?.ease == .land && fill?.keys.last?.t == 100)
        #expect(grant.restPose[KeysPage.ID.waitText, "opacity"] == .scalar(0))
    }

    @Test func easingMatchesItsEndsAndOvershootsOnlyWhenLanding() {
        for ease in [SceneEase.linear, .out, .in, .glide, .land, .hand] {
            #expect(ease.y(0) == 0 && ease.y(1) == 1)
        }
        #expect(SceneEase.step.y(0.99) == 0 && SceneEase.step.y(1) == 1)
        #expect((0...100).map { SceneEase.land.y(Double($0) / 100) }.max()! > 1)
        #expect((0...100).map { SceneEase.glide.y(Double($0) / 100) }.max()! <= 1)
    }

    @Test func theGateIsAPureFunctionOfWhatItSees() {
        var c = MotionGate.Conditions(active: true, reduceMotion: false, hasWindow: true, windowVisible: true,
                                      occluded: false, miniaturized: false, closing: false, appHidden: false,
                                      screensAsleep: false)
        #expect(MotionGate.evaluate(c))
        for change in [{ (c: inout MotionGate.Conditions) in c.active = false }, { $0.reduceMotion = true },
                       { $0.hasWindow = false }, { $0.windowVisible = false }, { $0.occluded = true },
                       { $0.miniaturized = true }, { $0.closing = true }, { $0.appHidden = true },
                       { $0.screensAsleep = true }] {
            var closed = c
            change(&closed)
            #expect(!MotionGate.evaluate(closed))
        }
        // Covered still counts as on screen (the permission fallback), Reduce Motion too.
        c.occluded = true
        c.reduceMotion = true
        #expect(c.onScreenIgnoringOcclusion)
        c.appHidden = true
        #expect(!c.onScreenIgnoringOcclusion)
    }

    @Test func aGateWithoutAVisibleWindowStaysShut() {
        let gate = MotionGate()
        gate.reduceMotionSource = { false }
        var changes: [Bool] = []
        gate.onChange = { changes.append($0) }
        gate.isActive = true
        #expect(!gate.isOpen && changes.isEmpty)
        // A window that was never ordered in is not visible: still shut, nothing plays.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        gate.attach(to: window)
        #expect(!gate.isOpen && changes.isEmpty && !gate.isOnScreenIgnoringOcclusion)
        gate.invalidate()
        #expect(!gate.isActive)
    }
}

@MainActor
@Suite("Defaults migration runs once")
struct DefaultsMigrationOnceTests {
    @Test func theImportRunsOnceSoErasedValuesDoNotReturn() throws {
        let legacyName = "keeplight-tests-legacy-\(UUID().uuidString)"
        let targetName = "keeplight-tests-target-\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        let target = try #require(UserDefaults(suiteName: targetName))
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            target.removePersistentDomain(forName: targetName)
        }
        legacy.set(["fp": "Desk"], forKey: "nicknames")
        legacy.set(30, forKey: "revertSeconds")
        #expect(DefaultsMigration.run(defaults: target, legacyDomain: legacyName) == ["nicknames", "revertSeconds"])
        #expect(target.dictionary(forKey: "nicknames") as? [String: String] == ["fp": "Desk"])
        // Erase All Keeplight Data removes the new domain; the next launch must not import again.
        target.removePersistentDomain(forName: targetName)
        #expect(DefaultsMigration.run(defaults: target, legacyDomain: legacyName).isEmpty)
        #expect(target.object(forKey: "nicknames") == nil)
        // The old app's own values are untouched.
        #expect(legacy.integer(forKey: "revertSeconds") == 30)
    }
}

@MainActor
@Suite("Dimmed range in the app")
struct DimmedRangeTests {
    @Test func aLevelSavedOnTheMonitorsOwnScaleMovesOntoTheDimmedRange() async {
        let rig = Rig()
        rig.desk.dimmer = SoftwareDimmer(tables: NoGammaTables())
        rig.desk.controls[7] = RecordingControl(displayID: 7, backend: .ddc, level: 0.28)
        // Saved by Dotpitch: the monitor's own 28 %, no `combined` flag.
        rig.model.prefs.lastWritten["TEST:1"] = LastWritten(value: 0.28, date: Date(), combined: nil)
        rig.model.refresh()
        #expect(await rig.eventually { rig.hasBrightness })
        let last = rig.model.prefs.lastWritten["TEST:1"]
        #expect(last?.combined == true)
        #expect(abs((last?.value ?? 0) - DimmingCurve.fromHardware(0.28)) < 1e-9)
        // The panel shows the same level on the new range.
        if case .available(_, let value?, _) = rig.model.brightness[7] {
            #expect(abs(value - DimmingCurve.fromHardware(0.28)) < 1e-9)
        } else {
            Issue.record("no brightness")
        }
    }

    @Test func zeroPercentKeepsTheBacklightAtZeroAndDimsFurther() async {
        let rig = Rig()
        let dimmer = SoftwareDimmer(tables: NoGammaTables())
        rig.desk.dimmer = dimmer
        let control = RecordingControl(displayID: 7, backend: .ddc, level: 0.5)
        rig.desk.controls[7] = control
        rig.model.refresh()
        #expect(await rig.eventually { rig.hasBrightness })
        rig.model.setBrightness(7, to: 0)
        // The throttle writes the trailing value; the monitor ends at its own 0.
        #expect(await rig.eventually { control.writes.last == 0 })
        if case .available(let wrapped, _, _) = rig.model.brightness[7] {
            #expect(wrapped.mechanism == "DDC VCP 0x10 + gamma")
        }
    }

    @Test func undoOfAnEntryFromBeforeTheDimmedRangeConvertsItsLevel() async {
        let rig = Rig()
        rig.desk.dimmer = SoftwareDimmer(tables: NoGammaTables())
        rig.desk.controls[7] = RecordingControl(displayID: 7, backend: .ddc, level: 0.5)
        rig.model.refresh()
        #expect(await rig.eventually { rig.hasBrightness })
        let old = JournalEntry(source: .panel, display: DisplayRef(name: "Test Display", fp: "TEST:1"), kind: .brightness,
                               before: "40%", after: "60%", mechanism: "DDC VCP 0x10", result: .applied)
        guard case .brightness(_, let to)? = rig.model.undoPlan(for: old) else { Issue.record("no plan"); return }
        #expect(abs(to - DimmingCurve.fromHardware(0.40)) < 1e-9)
        let new = JournalEntry(source: .panel, display: DisplayRef(name: "Test Display", fp: "TEST:1"), kind: .brightness,
                               before: "40%", after: "60%", mechanism: "DDC VCP 0x10 + gamma", result: .applied)
        guard case .brightness(_, let to2)? = rig.model.undoPlan(for: new) else { Issue.record("no plan"); return }
        #expect(abs(to2 - 0.40) < 1e-9)
    }
}
