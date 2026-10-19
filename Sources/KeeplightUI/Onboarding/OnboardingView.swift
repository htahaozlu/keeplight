import AppKit
import QuartzCore

/// The onboarding window's content (§4): the stage whose scene changes while its frame never
/// moves, the page's text column, progress segments bottom left and buttons bottom right. Pages
/// join by the page transition; page 3 runs the permission state machine of `OnboardingFlow`.
///
/// Motion follows the contract: every scene and transition is a `SceneTimeline` played on the
/// render server, and nothing moves unless the `MotionGate` is open. When it closes everything
/// stops at its rest pose (Reduce Motion: the explain pose, which here is the rest pose too).
///
/// The only timer lives here: the 1 Hz permission fallback (tolerance 0.5), only while page 3
/// waits and is on screen — covered by System Settings counts, hidden or asleep does not.
final class OnboardingView: OnboardingContentView {
    let flow: OnboardingFlow
    private var model: AppModel { flow.model }
    /// Done, Not Now, Esc: the owner closes the window.
    var onFinish: (() -> Void)?
    /// Access arrived: the owner activates the app and brings the window front.
    var onGranted: (() -> Void)?

    let stage = StageView(frame: OnboardingMetrics.stage)
    let progress = ProgressSegments(frame: .zero)
    let backButton = NSButton(title: OnboardingCopy.back, target: nil, action: nil)
    let secondaryButton = NSButton(title: OnboardingCopy.notNow, target: nil, action: nil)
    let primaryButton = NSButton(title: OnboardingCopy.continueLabel, target: nil, action: nil)

    let welcome: WelcomePage
    let keep: KeepPage
    let keys: KeysPage
    let light = LightScene()
    let fuse = FuseScene()
    let keysScene = KeysScene()
    let access = AccessScene()

    let gate = MotionGate()
    private(set) var palette: StagePalette?
    /// The step and page-3 state on screen (the flow's may be ahead during a transition).
    private(set) var shownStep: OnboardingStep
    private var transitioning = false
    private var transitionFrom: OnboardingStep?
    private var swapping: StageScene?
    private var playing = false
    private var motionToken = 0
    private var transitionToken = 0
    /// Scenes that ran all their cycles; they rest until a replay.
    private var played: Set<String> = []
    private var trustTimer: Timer?
    private var observers: [any NSObjectProtocol] = []
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var torn = false
    private weak var observedWindow: NSWindow?

    init(flow: OnboardingFlow) {
        self.flow = flow
        let frame = CGRect(x: OnboardingMetrics.columnX, y: OnboardingMetrics.pageTop, width: OnboardingMetrics.columnWidth,
                           height: OnboardingMetrics.pageHeight)
        welcome = WelcomePage(frame: frame)
        keep = KeepPage(frame: frame)
        keys = KeysPage(frame: frame)
        shownStep = flow.step
        super.init(frame: CGRect(origin: .zero, size: OnboardingMetrics.size))
        build()
    }

    // MARK: building

    private func build() {
        addSubview(stage)
        stage.onReplay = { [weak self] in self?.replay() }
        stage.onAppearanceChange = { [weak self] in self?.applyPalette() }
        addSubview(progress)

        backButton.target = self
        backButton.action = #selector(back(_:))
        backButton.keyEquivalent = "["
        backButton.keyEquivalentModifierMask = .command
        backButton.toolTip = "⌘["
        secondaryButton.target = self
        secondaryButton.action = #selector(notNow(_:))
        primaryButton.target = self
        primaryButton.action = #selector(primary(_:))
        primaryButton.keyEquivalent = "\r"
        for b in [backButton, secondaryButton, primaryButton] {
            b.bezelStyle = .push
            b.controlSize = .large
            addSubview(b)
        }
        for row in [keep.login, keys.login] {
            row.toggle.state = flow.openAtLogin ? .on : .off
            row.toggle.target = self
            row.toggle.action = #selector(toggleLogin(_:))
        }

        gate.onChange = { [weak self] _ in self?.motionChanged() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.checkTrust() }
        })
        // The fallback follows what the gate sees even while Reduce Motion keeps the gate shut (its
        // `onChange` never fires then): re-read once the gate's own observers ran.
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTrustTimerSoon() }
            })
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated {
                    self?.applyPalette()
                    self?.updateTrustTimerSoon()
                }
            })
        }
        refreshFromModel()
        applyPalette()
        install(step: flow.step)
        observeModel()
    }

    /// Re-reads the model whenever what the pages show changes (displays found, the tap started).
    private func observeModel() {
        guard !torn else { return }
        withObservationTracking {
            _ = model.items
            _ = model.brightness
            _ = model.brightnessKeysActive
            _ = model.prefs.nicknames
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshFromModel()
                self?.observeModel()
            }
        }
    }

    private func refreshFromModel() {
        let screens = model.items.filter { !$0.info.isMirrorTarget }
            .map { LightScene.Screen(name: model.name($0.info), bounds: $0.info.bounds) }
        if screens != light.screens, !(shownStep == .welcome && playing) {
            light.configure(screens.isEmpty ? light.screens : screens)
            if let palette { light.apply(palette) }
            if shownStep == .welcome, !transitioning { showStatic() }
        }
        let names = flow.keyableDisplayNames
        keys.update(names: names, isLast: flow.steps.last == .keys)
        keysScene.configure(name: names.count == 1 ? names[0] : nil)
        keep.update(isLast: flow.steps.last == .keep)
        progress.count = flow.steps.count
        progress.current = flow.index
        if flow.syncPermission() { grantArrived() }
        updateButtons()
    }

    // MARK: window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !torn else { return }
        gate.attach(to: window)
        gate.isActive = window != nil
        if let window, window !== observedWindow {
            observedWindow = window
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateTrustTimerSoon() }
                })
            }
        }
        applyPalette()
    }

    /// The window is up: start what the page does.
    func didAppear() {
        gate.update()
        pageDidAppear()
    }

    /// The window closed: every animation, observer and the timer go.
    func teardown() {
        guard !torn else { return }
        torn = true
        stopTrustTimer()
        gate.onChange = nil
        gate.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        workspaceObservers = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in scenes { for l in s.allLayers { l.removeAllAnimations() } }
        CATransaction.commit()
    }

    // MARK: pages

    private func page(_ step: OnboardingStep) -> OnboardingPage {
        switch step {
        case .welcome: welcome
        case .keep: keep
        case .keys: keys
        }
    }

    /// The scene a step shows now.
    private func scene(_ step: OnboardingStep) -> StageScene {
        switch step {
        case .welcome: light
        case .keep: fuse
        case .keys: flow.permission == .waiting || flow.permission == .granted ? access : keysScene
        }
    }

    private var keysShown: KeysPage.Shown {
        switch flow.permission {
        case .notAsked, .deferred: .notAsked
        case .waiting: .waiting
        case .granted: .granted
        }
    }

    private var pages: [OnboardingPage] { [welcome, keep, keys] }
    private var scenes: [StageScene] { [light, fuse, keysScene, access] }

    /// Puts `step` up without animation.
    private func install(step: OnboardingStep) {
        shownStep = step
        for p in pages where p !== page(step) { p.removeFromSuperview() }
        let current = scene(step)
        for s in scenes where s !== current { s.root.removeFromSuperlayer() }
        add(page: page(step))
        add(scene: current)
        stage.scene = current
        if step == .keys { keys.show(keysShown) }
        progress.current = flow.index
        updateButtons()
        showStatic()
    }

    private func add(page: OnboardingPage) {
        guard page.superview == nil else { return }
        page.frame = CGRect(x: OnboardingMetrics.columnX, y: OnboardingMetrics.pageTop, width: OnboardingMetrics.columnWidth,
                            height: OnboardingMetrics.pageHeight)
        addSubview(page)
    }

    private func add(scene: StageScene) {
        guard scene.root.superlayer == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.root.opacity = 1
        scene.root.setValue(1, forKeyPath: "transform.scale")
        stage.content.addSublayer(scene.root)
        CATransaction.commit()
    }

    /// Shows the flow's step, with the page transition when the window is seen.
    private func go(animated: Bool) {
        let to = flow.step
        let from = shownStep
        guard to != from, !transitioning else { return updateButtons() }
        // The old page leaves showing its scene's rest picture, not its blank first frame.
        freezeAtRest(scene(from))
        stopTrustTimer()
        guard animated, window?.isVisible == true, gate.conditionsMet,
              page(from).superview != nil else {
            install(step: to)
            pageDidAppear()
            return
        }
        let (timeline, layers) = beginTransition(from: from, to: to, reduceMotion: gate.reduceMotion)
        page(from).alphaValue = 0
        page(to).alphaValue = 1
        transitioning = true
        transitionFrom = from
        transitionToken += 1
        let token = transitionToken
        ScenePlayer.play([timeline], on: layers) { [weak self] in
            guard let self, self.transitionToken == token else { return }
            self.endTransition()
        }
    }

    /// Both pages and scenes in place for the transition; returns its timeline and layers.
    private func beginTransition(from: OnboardingStep, to: OnboardingStep, reduceMotion rm: Bool)
        -> (SceneTimeline, [LayerID: CALayer]) {
        typealias ID = OnboardingTimelines.PageID
        let old = page(from), new = page(to)
        let oldScene = scene(from), newScene = scene(to)
        add(page: new)
        add(scene: newScene)
        if to == .keys { keys.show(keysShown) }
        newScene.show(entryPose(newScene))
        var colors: [LayerID: (from: CGColor, to: CGColor)] = [:]
        let fromIndex = flow.steps.firstIndex(of: from) ?? 0
        for i in 0..<progress.count {
            if let a = progress.color(i, current: fromIndex), let b = progress.color(i, current: flow.index) {
                colors[ProgressSegments.id(i)] = (a, b)
            }
        }
        progress.current = flow.index
        shownStep = to
        stage.scene = newScene
        updateButtons()
        var layers = progress.layers
        layers[ID.oldPage] = old.layer
        layers[ID.newPage] = new.layer
        layers[ID.oldScene] = oldScene.root
        layers[ID.newScene] = newScene.root
        let forward = (flow.steps.firstIndex(of: to) ?? 0) > fromIndex
        return (OnboardingTimelines.page(forward: forward, progress: colors, reduceMotion: rm), layers)
    }

    private func endTransition() {
        guard transitioning else { return }
        transitionToken += 1
        transitioning = false
        if let from = transitionFrom { cleanUpTransition(from: from) }
        transitionFrom = nil
        pageDidAppear()
    }

    private func cleanUpTransition(from: OnboardingStep) {
        let old = page(from), oldScene = scene(from) === scene(shownStep) ? nil : scene(from)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let current = page(shownStep)
        for l in [old.layer, current.layer, oldScene?.root, scene(shownStep).root].compactMap({ $0 }) + progress.segments {
            l.removeAllAnimations()
        }
        old.removeFromSuperview()
        old.alphaValue = 1
        old.layer?.setValue(0, forKeyPath: "transform.translation.x")
        current.alphaValue = 1
        current.layer?.setValue(0, forKeyPath: "transform.translation.x")
        for s in scenes where s !== scene(shownStep) { s.root.removeFromSuperlayer() }
        CATransaction.commit()
        progress.apply(palette ?? StagePalette.resolve(effectiveAppearance))
    }

    /// The page is seen: start what belongs to it, move VoiceOver to its title.
    private func pageDidAppear() {
        updateTrustTimer()
        if let title = page(shownStep).titleField, window != nil { OnboardingSpeech.focus(title) }
        if window?.firstResponder !== primaryButton { window?.makeFirstResponder(primaryButton) }
        if gate.isOpen { resumeMotion() } else if !playing { showStatic() }
    }

    // MARK: buttons

    private func updateButtons() {
        let step = shownStep
        backButton.isHidden = step == .welcome || (step == .keys && flow.permission == .granted)
        secondaryButton.isHidden = !(step == .keys && flow.permission != .granted)
        switch step {
        case .welcome: primaryButton.title = OnboardingCopy.continueLabel
        case .keep: primaryButton.title = flow.steps.last == .keep ? OnboardingCopy.done : OnboardingCopy.continueLabel
        case .keys:
            primaryButton.title = switch flow.permission {
            case .notAsked, .deferred: OnboardingCopy.allow
            case .waiting: OnboardingCopy.openSystemSettings
            case .granted: OnboardingCopy.done
            }
        }
        layoutBar()
    }

    /// Bottom bar: progress at the left, buttons right-aligned (Back · secondary · primary).
    private func layoutBar() {
        let mid = OnboardingMetrics.size.height - OnboardingMetrics.barHeight / 2
        let size = progress.intrinsicContentSize
        progress.frame = CGRect(x: OnboardingMetrics.columnX, y: mid - 6, width: size.width, height: 12)
        var x = OnboardingMetrics.columnX + OnboardingMetrics.columnWidth
        for b in [primaryButton, secondaryButton, backButton] where !b.isHidden {
            b.sizeToFit()
            let w = max(ceil(b.frame.width), OnboardingMetrics.buttonMinWidth), h = ceil(b.frame.height)
            x -= w
            b.frame = CGRect(x: x, y: (mid - h / 2).rounded(), width: w, height: h)
            x -= OnboardingMetrics.buttonGap
        }
    }

    // MARK: actions

    @objc private func primary(_ sender: Any?) {
        guard !transitioning else { return } // a double click must not skip a page
        if let e = NSApp.currentEvent, e.type == .keyDown, e.isARepeat { return } // held Return
        switch shownStep {
        case .welcome, .keep:
            flow.advance()
            flow.isFinished ? onFinish?() : go(animated: true)
        case .keys:
            switch flow.permission {
            case .notAsked, .deferred: allow()
            case .waiting: model.openAccessibilitySettings()
            case .granted:
                flow.advance()
                onFinish?()
            }
        }
    }

    @objc private func back(_ sender: Any?) {
        guard !transitioning, !backButton.isHidden else { return }
        flow.back()
        go(animated: true)
    }

    @objc private func notNow(_ sender: Any?) {
        guard !transitioning else { return }
        flow.notNow()
        onFinish?()
    }

    @objc private func toggleLogin(_ sender: NSSwitch) {
        flow.openAtLogin = sender.state == .on
        for row in [keep.login, keys.login] where row.toggle !== sender { row.toggle.state = sender.state }
    }

    /// Esc: closes on pages 1–2, is `Not Now` on page 3.
    func cancel() {
        guard !transitioning else { return }
        if shownStep == .keys, flow.permission != .granted { return notNow(nil) }
        flow.finish(applyLogin: false)
        onFinish?()
    }

    private func allow() {
        let old = keysShown
        let oldScene = scene(.keys)
        flow.allow()
        let new = keysShown
        updateButtons()
        animateKeys(from: old, to: new, oldScene: oldScene)
        if new == .granted { grantSideEffects() }
        updateTrustTimer()
    }

    // MARK: page 3 state

    /// Page 3's row and scene follow the permission: cross-fades on the row, the scene hands over
    /// (Keys → Access), and the granted moment fills the ring.
    private func animateKeys(from old: KeysPage.Shown, to new: KeysPage.Shown, oldScene: StageScene) {
        guard shownStep == .keys, !transitioning, old != new else {
            if shownStep == .keys, !transitioning { keys.show(new) }
            return
        }
        let newScene = scene(.keys)
        let animate = window?.isVisible == true && gate.conditionsMet
        // Read before `stopMotion()` resets the layers: the cursor leaves from where it is now.
        let grantedTarget = access.timeline.restPose.merging(AccessScene.grantedPose)
        let grantedFrom = ScenePlayer.presentationPose(like: grantedTarget, in: access.layers)
        stopMotion()
        if !animate {
            keys.show(new)
            if newScene !== oldScene { install(step: .keys) }
            showStatic()
            return
        }
        let rm = gate.reduceMotion
        keys.prepare(from: old, to: new)
        let state = OnboardingTimelines.keysState(from: old, to: new, reduceMotion: rm)
        var timelines = [state]
        var layers = keys.stateLayers
        if newScene !== oldScene {
            add(scene: newScene)
            newScene.show(entryPose(newScene))
            stage.scene = newScene
            layers[OnboardingTimelines.SceneSwapID.old] = oldScene.root
            layers[OnboardingTimelines.SceneSwapID.new] = newScene.root
            timelines.append(OnboardingTimelines.sceneSwap(reduceMotion: rm))
            swapping = oldScene
        } else if new == .granted {
            // The switch stays on and the cursor leaves, from wherever the loop was.
            timelines.append(SceneTimeline.move(name: "onb.access.granted", from: grantedFrom, to: grantedTarget,
                                                duration: rm ? OnboardingTheme.Motion.reduced : 240, ease: .out))
            layers.merge(access.layers) { $1 }
        }
        motionToken += 1
        let token = motionToken
        playing = true
        ScenePlayer.play(timelines, on: layers) { [weak self] in
            guard let self, self.motionToken == token else { return }
            self.playing = false
            self.endKeysChange()
        }
    }

    private func endKeysChange() {
        if let old = swapping {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            old.root.removeAllAnimations()
            old.root.removeFromSuperlayer()
            old.root.opacity = 1
            CATransaction.commit()
            swapping = nil
        }
        keys.show(keysShown)
        if gate.isOpen { resumeMotion() } else { showStatic() }
    }

    private func checkTrust() {
        guard !torn else { return }
        if flow.checkTrust() { grantArrived() }
    }

    /// Access arrived (event, re-check or the fallback timer).
    private func grantArrived() {
        updateButtons()
        stopTrustTimer()
        animateKeys(from: .waiting, to: .granted, oldScene: access)
        grantSideEffects()
    }

    private func grantSideEffects() {
        OnboardingSpeech.announce(OnboardingCopy.keysOn)
        onGranted?()
    }

    // MARK: permission fallback

    private func updateTrustTimer() {
        guard !torn else { return }
        let onScreen = window != nil && gate.isOnScreenIgnoringOcclusion && shownStep == .keys && !transitioning
        guard flow.wantsTrustPolling(onScreen: onScreen) else { return stopTrustTimer() }
        guard trustTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    /// After the current notification's other observers (the gate's) ran.
    private func updateTrustTimerSoon() {
        Task { @MainActor [weak self] in self?.updateTrustTimer() }
    }

    private func stopTrustTimer() {
        trustTimer?.invalidate()
        trustTimer = nil
    }

    /// Whether the 1 Hz fallback is scheduled (tests, render tool).
    var isPollingTrust: Bool { trustTimer != nil }

    // MARK: motion

    private func motionChanged() {
        updateTrustTimer()
        if gate.isOpen {
            resumeMotion()
        } else {
            if transitioning { endTransition() }
            // A Keys → Access hand-over or the granted moment cut short: finish it now, or the old
            // scene, the half-prepared row and `swapping` (which blocks replay) would stay.
            if swapping != nil || (playing && shownStep == .keys) { endKeysChange() }
            stopMotion()
        }
    }

    /// What the current page plays when it may move.
    private func resumeMotion() {
        guard gate.isOpen, !transitioning, !playing, window != nil else { return }
        let s = scene(shownStep)
        if shownStep == .keys, flow.permission == .granted { return showStatic() }
        guard !played.contains(s.timeline.name) else { return showStatic() }
        play(s, loops: s.loops)
    }

    private func play(_ s: StageScene, loops: Int) {
        motionToken += 1
        let token = motionToken
        for l in s.allLayers { l.removeAllAnimations() }
        playing = true
        let name = s.timeline.name
        ScenePlayer.play([s.timeline], on: s.layers, loops: loops) { [weak self] in
            guard let self, self.motionToken == token else { return }
            self.playing = false
            self.played.insert(name)
        }
    }

    /// Every animation off; `s` at its rest pose (granted access keeps the switch on).
    private func freezeAtRest(_ s: StageScene) {
        motionToken += 1
        playing = false
        for l in s.allLayers { l.removeAllAnimations() }
        let rest = s === access && flow.permission == .granted
            ? s.timeline.restPose.merging(AccessScene.grantedPose) : s.timeline.restPose
        s.show(rest)
    }

    /// Every animation off; the page at its static pose.
    private func stopMotion() {
        motionToken += 1
        playing = false
        showStatic()
    }

    /// Offscreen renders: every scene shows its explainT pose, never a first frame.
    var showsStills = false

    /// The pose a scene enters with: its first frame when it will play, else its rest.
    private func entryPose(_ s: StageScene) -> ScenePose {
        if s === access, flow.permission == .granted {
            return (showsStills ? s.timeline.explainPose : s.timeline.restPose).merging(AccessScene.grantedPose)
        }
        if showsStills { return s.timeline.explainPose }
        let willPlay = !gate.reduceMotion && !played.contains(s.timeline.name)
        return willPlay ? s.timeline.pose(at: 0) : s.timeline.restPose
    }

    /// The static picture of the page: rest (= explainT for every scene), or the first frame of a
    /// scene about to play.
    func showStatic() {
        guard palette != nil else { return }
        let s = scene(shownStep)
        s.show(entryPose(s))
    }

    /// A click on the stage, Space on it, or VoiceOver's Replay: one more cycle.
    private func replay() {
        guard !transitioning, gate.isOpen, swapping == nil else { return } // hidden or Reduce Motion: the picture stays
        if shownStep == .keys, flow.permission == .granted { return }
        play(scene(shownStep), loops: 1)
    }

    // MARK: appearance

    func applyPalette() {
        let p = StagePalette.resolve(effectiveAppearance)
        palette = p
        let scale = window?.backingScaleFactor ?? 2
        for s in scenes {
            s.setScale(scale)
            s.apply(p)
        }
        stage.apply(p)
        progress.apply(p)
        pages.forEach { $0.apply(p) }
        needsDisplay = true
        if !playing, !transitioning { showStatic() }
    }

    // MARK: offscreen renders

    /// The render tool: the flow's step and page-3 state as a still at the scene's explainT.
    func showStill() {
        showsStills = true
        install(step: flow.step)
    }
}
