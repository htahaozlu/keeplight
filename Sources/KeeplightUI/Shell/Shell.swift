import AppKit
import DisplayCore
import SwiftUI

/// The AppKit shell: status item, panel, onboarding, per-screen Keep card, Identify, OSD and rescue
/// HUD windows, Settings.
@MainActor
final class Shell: ShellActions {
    private let model: AppModel
    private var status: StatusItemController!
    private var panel: PanelController!
    private let settings: SettingsWindowController
    /// One Keep card per screen, keyed by the screen's display ID.
    private var rings: [(screen: CGDirectDisplayID?, window: InstrumentPanel)] = []
    private var ringWindows: [InstrumentPanel] { rings.map(\.window) }
    /// Cards that have resolved and are holding / fading out.
    private var retiring: [InstrumentPanel] = []
    private let keepState = KeepCardState()
    private var screenObserver: (any NSObjectProtocol)?
    private var relayoutTask: Task<Void, Never>?
    private var identifyWindows: [InstrumentPanel] = []
    private var keyMonitor: Any?
    private var osdWindow: InstrumentPanel?
    private let osdState = BrightnessOSDState()
    private var osdHideTask: Task<Void, Never>?
    private var osdFading = false
    private var osdAnnouncedAt = Date.distantPast
    private var rescueWindows: [(screen: CGDirectDisplayID?, window: InstrumentPanel)] = []
    private let rescueState = RescueHUDState()
    private var rescueLifecycle = RescueHUDLifecycle()
    private var onboarding: OnboardingWindowController?
    var isOnboardingOpen: Bool { onboarding != nil }

    init(model: AppModel) {
        self.model = model
        settings = SettingsWindowController(model: model)
        model.shell = self
        status = StatusItemController(model: model) { [weak self] in self?.togglePanel() }
        panel = PanelController(model: model, anchor: { [weak self] in self?.status.anchorRect },
                                statusWindow: { [weak self] in self?.status.window })
        installKeyMonitor()
    }

    var isPanelOpen: Bool { panel.isOpen }

    // MARK: Panel

    func openPanel() { panel.open() }
    func closePanel() { panel.close() }
    func togglePanel() { panel.toggle() }

    func showSettings() { settings.show() }

    // MARK: Onboarding

    /// The onboarding window (once per launch while `onboardingVersion` is behind).
    func showOnboarding() {
        if onboarding == nil {
            let controller = OnboardingWindowController(model: model)
            controller.onClose = { [weak self] in self?.onboarding = nil }
            onboarding = controller
        }
        onboarding?.show()
    }

    // MARK: Brightness OSD

    /// Shows (or updates) the brightness-key OSD near the bottom of display `id`'s screen and
    /// hides it 1.2 s after the last press.
    func showBrightnessOSD(on id: CGDirectDisplayID, value: Double) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) ?? NSScreen.main else { return }
        let keyable = model.items.filter { model.brightness[$0.id]?.control?.backend == .ddc }
        osdState.value = value
        osdState.name = keyable.count > 1 ? keyable.first { $0.id == id }.map { model.name($0.info) } : nil
        let size = CGSize(width: BrightnessOSDView.width, height: BrightnessOSDView.height(named: osdState.name != nil))
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 120,
                           width: size.width, height: size.height)
        let window: InstrumentPanel
        if let existing = osdWindow {
            window = existing
        } else {
            window = InstrumentPanel(frame: frame, interactive: false)
            window.host(BrightnessOSDView(state: osdState))
            osdWindow = window
        }
        window.setFrame(frame, display: true)
        if !window.isVisible {
            window.set(pose: Timeline.osdShow.keyframes[0].pose)
            window.orderFrontRegardless()
            osdFading = false
            window.play(.osdShow)
        } else if osdFading {
            osdFading = false
            window.play(.osdShow)
        }
        let now = Date()
        if now.timeIntervalSince(osdAnnouncedAt) >= 0.5 {
            osdAnnouncedAt = now
            model.announce(OverlayCopy.osdLabel(percent: BrightnessPolicy.percent(value)))
        }
        osdHideTask?.cancel()
        osdHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, let window = self.osdWindow else { return }
            self.osdFading = true
            window.play(.osdHide) { [weak self, weak window] in
                window?.orderOut(nil)
                guard let self else { return }
                self.osdFading = false
                // Gone for good: the window and its hosting view are rebuilt on the next key press.
                if self.osdWindow === window { self.osdWindow = nil }
            }
        }
    }

    // MARK: Keep card

    /// Pushes the model's pending change (title, phase, lit Fuse dots) into the card state. Runs
    /// when the card appears, once per second while pending, and when the change resolves.
    func syncRing() {
        guard let info = model.ringInfo else { return }
        let phase: KeepCardState.Phase = switch model.ringPhase {
        case .live: .live
        case .sealed: .kept
        case .reverted: .reverted
        case .revertFailed: .revertFailed
        }
        let lit = FuseClock.lit(elapsed: Date().timeIntervalSince(info.startedAt), total: info.duration)
        if keepState.title != info.title { keepState.title = info.title }
        if keepState.phase != phase { keepState.phase = phase }
        if keepState.lit != lit { keepState.lit = lit }
        let perDot = info.duration / Double(Metrics.fuseCount)
        if keepState.secondsPerDot != perDot { keepState.secondsPerDot = perDot }
    }

    func showRing() {
        dismissRing(animated: false)
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            model.previousApp = front
        }
        keepState.height = nil
        syncRing()
        keepState.height = max(Metrics.keepCardSize.height, ceil(InstrumentPanel.fittingSize(of: cardView()).height))
        for screen in NSScreen.screens {
            let window = makeRing(on: screen)
            window.set(pose: Timeline.cardIn.keyframes[0].pose)
            window.orderFrontRegardless()
            window.play(.cardIn)
            rings.append((screen.displayID, window))
        }
        NSApp.activate()
        makePointerRingKey()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRingRelayout() }
        }
    }

    private func cardView() -> some View {
        KeepCardView(state: keepState, onKeep: { [model] in model.keepPending() },
                     onRevert: { [model] in model.revertPending(.user) })
    }

    private var cardSize: CGSize { CGSize(width: Metrics.keepCardSize.width, height: keepState.height ?? Metrics.keepCardSize.height) }

    private func makeRing(on screen: NSScreen) -> InstrumentPanel {
        let window = InstrumentPanel(frame: InstrumentPanel.frame(size: cardSize, on: screen, topFraction: 0.36),
                                     interactive: true)
        window.host(cardView())
        return window
    }

    private func makePointerRingKey() {
        let pointer = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let key = rings.first { $0.screen == pointer?.displayID }?.window ?? rings.first?.window
        key?.makeKeyAndOrderFront(nil)
    }

    /// Screens came, went or changed size (often the pending change itself): coalesce, then keep
    /// exactly one card per current screen.
    private func scheduleRingRelayout() {
        relayoutTask?.cancel()
        relayoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.relayoutRings()
        }
    }

    private func relayoutRings() {
        guard !rings.isEmpty else { return }
        let screens = NSScreen.screens
        let wasKey = rings.contains { $0.window.isKeyWindow }
        var next: [(screen: CGDirectDisplayID?, window: InstrumentPanel)] = []
        for ring in rings {
            if let screen = screens.first(where: { $0.displayID == ring.screen }),
               !next.contains(where: { $0.screen == ring.screen }) {
                ring.window.setFrame(InstrumentPanel.frame(size: cardSize, on: screen, topFraction: 0.36), display: true)
                next.append(ring)
            } else {
                ring.window.cancelPlayback()
                ring.window.orderOut(nil)
            }
        }
        for screen in screens where !next.contains(where: { $0.screen == screen.displayID }) {
            let window = makeRing(on: screen)
            window.set(pose: Timeline.cardIn.keyframes[0].pose)
            window.orderFrontRegardless()
            window.play(.cardIn)
            next.append((screen.displayID, window))
        }
        rings = next
        if wasKey, !rings.contains(where: { $0.window.isKeyWindow }) { makePointerRingKey() }
    }

    /// `animated`: the card shows its resolved word and symbol for 700 ms, then fades; otherwise
    /// it disappears at once.
    func dismissRing(animated: Bool) {
        let windows = ringWindows
        rings = []
        relayoutTask?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if !animated {
            for window in retiring { window.cancelPlayback(); window.orderOut(nil) }
            retiring = []
        }
        guard !windows.isEmpty else { return }
        let previous = model.previousApp
        model.previousApp = nil
        if animated {
            retiring += windows
            for window in windows {
                window.play(.cardResolved, staticHold: 0.7) { [weak self, weak window] in
                    guard let self, let window else { return }
                    window.orderOut(nil)
                    self.retiring.removeAll { $0 === window }
                    if self.retiring.isEmpty, self.rings.isEmpty, self.model.pending == nil { self.model.ringInfo = nil }
                }
            }
        } else {
            for window in windows { window.cancelPlayback(); window.orderOut(nil) }
        }
        // Still in the panel: it keeps the keyboard (Esc closes it). Otherwise focus goes back.
        if panel.isOpen {
            panel.window.makeKey()
        } else if let previous, !settings.isVisible {
            previous.activate()
        }
    }

    /// Return keeps and Esc reverts while a change is pending and one of our windows is key.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.model.pending != nil,
                      event.window is InstrumentPanel || event.window is KeeplightPanel else { return false }
                switch event.keyCode {
                case 36, 76:
                    // A held or doubled Return from choosing the mode must not keep it.
                    if !event.isARepeat, event.timestamp >= self.model.ringShownUptime { self.model.keepPending() }
                    return true
                case 53:
                    self.model.revertPending(.esc)
                    return true
                default:
                    return false
                }
            }
            return consumed ? nil : event
        }
    }

    // MARK: Identify

    /// The name of every display on its own screen. All cards appear together and leave after
    /// 1.56 s.
    func identify() {
        for window in identifyWindows { window.cancelPlayback(); window.orderOut(nil) }
        identifyWindows = []
        var names: [String] = []
        for item in model.items {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == item.id }) else { continue }
            let name = model.name(item.info)
            let window = InstrumentPanel(frame: .zero, interactive: false)
            let view = IdentifyView(name: name)
            window.host(view)
            let size = CGSize(width: IdentifyView.width,
                              height: max(IdentifyView.minHeight, ceil(InstrumentPanel.fittingSize(of: view).height)))
            window.setFrame(InstrumentPanel.frame(size: size, on: screen, centerFraction: 0.40), display: true)
            window.set(pose: Timeline.identify.keyframes[0].pose)
            window.orderFrontRegardless()
            window.play(.identify, staticHold: 1.32) { [weak self, weak window] in
                guard let self, let window else { return }
                window.orderOut(nil)
                self.identifyWindows.removeAll { $0 === window }
            }
            identifyWindows.append(window)
            names.append(name)
        }
        if !names.isEmpty { model.announce(OverlayCopy.identifyAnnouncement(names)) }
    }

    // MARK: Rescue HUD

    /// The rescue HUD on every screen: appears while the chord is held, shows the result, then
    /// leaves. `.hidden` removes it at once.
    func rescueHUD(_ phase: RescueHUDPhase) {
        switch phase {
        case .hidden:
            closeRescueHUD()
        case .holding:
            let replay = rescueLifecycle.holding()
            rescueState.phase = phase
            reconcileRescueWindows(pose: Timeline.rescueIn.keyframes[0].pose)
            if replay {
                // Also over the previous result: stop its fade (and the close that follows it).
                for entry in rescueWindows {
                    entry.window.cancelPlayback()
                    entry.window.set(pose: Timeline.rescueIn.keyframes[0].pose)
                    entry.window.play(.rescueIn)
                }
                model.announce(OverlayCopy.rescueHolding)
            }
        case .done(let text, _):
            let ticket = rescueLifecycle.showResult()
            rescueState.phase = phase
            reconcileRescueWindows(pose: Pose(opacity: 1))
            for entry in rescueWindows {
                entry.window.play(.rescueDone, staticHold: 1.6) { [weak self] in
                    guard let self, self.rescueLifecycle.shouldClose(ticket: ticket) else { return }
                    self.closeRescueHUD()
                }
            }
            model.announce(text)
        }
    }

    /// One HUD window per current screen, kept when the screen is unchanged.
    private func reconcileRescueWindows(pose: Pose) {
        let screens = NSScreen.screens
        var next: [(screen: CGDirectDisplayID?, window: InstrumentPanel)] = []
        for entry in rescueWindows {
            if screens.contains(where: { $0.displayID == entry.screen }) {
                next.append(entry)
            } else {
                entry.window.cancelPlayback()
                entry.window.orderOut(nil)
            }
        }
        for screen in screens where !next.contains(where: { $0.screen == screen.displayID }) {
            let window = InstrumentPanel(frame: InstrumentPanel.frame(size: Metrics.rescueCardSize, on: screen,
                                                                      centerFraction: 0.40), interactive: false)
            window.host(RescueHUDView(state: rescueState))
            window.set(pose: pose)
            window.orderFrontRegardless()
            next.append((screen.displayID, window))
        }
        rescueWindows = next
    }

    private func closeRescueHUD() {
        rescueLifecycle.hide()
        for entry in rescueWindows { entry.window.cancelPlayback(); entry.window.orderOut(nil) }
        rescueWindows = []
    }
}
