import AppKit

/// Visibility gate for moving surfaces (docs/DESIGN.md motion contract; ported from Nokta). A scene
/// may animate only while all of these hold: the owner wants it (`isActive`: page shown), the
/// window is visible, not occluded, not miniaturized and not closing, the app is not hidden, the
/// displays are awake and Reduce Motion is off.
///
/// Event driven, never polled: window occlusion / miniaturize / close, app hide / unhide, screens
/// sleep / wake and the accessibility display options re-evaluate the gate. `onChange` fires only
/// when `isOpen` flips; on close the owner removes its animations and shows the rest pose, on open
/// looping scenes start over.
///
///     let gate = MotionGate()
///     gate.onChange = { [weak self] open in open ? self?.play() : self?.stopAtRest() }
///     gate.attach(to: window)
///     gate.isActive = true
@MainActor
final class MotionGate {
    /// What the gate looks at, for `evaluate`.
    struct Conditions: Equatable, Sendable {
        var active = false
        var reduceMotion = false
        var hasWindow = false
        var windowVisible = false
        var occluded = true
        var miniaturized = false
        var closing = false
        var appHidden = false
        var screensAsleep = false

        /// Seen by the user, possibly behind another window.
        var onScreenIgnoringOcclusion: Bool {
            hasWindow && windowVisible && !miniaturized && !closing && !appHidden && !screensAsleep
        }
    }

    /// Pure: whether scenes may move under `c`.
    static func evaluate(_ c: Conditions) -> Bool {
        c.active && !c.reduceMotion && c.onScreenIgnoringOcclusion && !c.occluded
    }

    /// The owner's own condition (page visible, scene wanted). Off by default.
    var isActive = false { didSet { update() } }
    /// Called when `isOpen` changes.
    var onChange: ((Bool) -> Void)?
    /// Reduce Motion as the system reports it; replaceable for tests and offscreen renders.
    var reduceMotionSource: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private(set) var isOpen = false
    var reduceMotion: Bool { reduceMotionSource() }

    private weak var window: NSWindow?
    private var windowObservers: [any NSObjectProtocol] = []
    private var appObservers: [any NSObjectProtocol] = []
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var miniaturizing = false
    private var closing = false
    private var screensAsleep = false
    private var sessionAway = false

    init() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            appObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil,
                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = true
                self?.update()
            }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil,
                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = false
                self?.update()
            }
        })
        // Fast user switching: another user's session is in front, our screens are not seen and
        // they do not sleep. Counts as asleep (stops scenes and the permission fallback timer).
        for (name, away) in [(NSWorkspace.sessionDidResignActiveNotification, true),
                             (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionAway = away
                    self?.update()
                }
            })
        }
    }

    /// Drops every observer (the owner's window closed for good).
    func invalidate() {
        (windowObservers + appObservers).forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        windowObservers = []
        appObservers = []
        workspaceObservers = []
        window = nil
        isActive = false
    }

    /// Follows `window` (nil detaches).
    func attach(to window: NSWindow?) {
        guard window !== self.window || windowObservers.isEmpty else { update(); return }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        self.window = window
        miniaturizing = false
        closing = false
        if let window {
            let nc = NotificationCenter.default
            func on(_ name: Notification.Name, _ body: @escaping @MainActor (MotionGate) -> Void) {
                windowObservers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        body(self)
                        self.update()
                    }
                })
            }
            on(NSWindow.didChangeOcclusionStateNotification) { gate in
                if gate.window?.isVisible == true { gate.closing = false } // shown again after a close
            }
            on(NSWindow.willMiniaturizeNotification) { $0.miniaturizing = true }
            on(NSWindow.didMiniaturizeNotification) { $0.miniaturizing = true }
            on(NSWindow.didDeminiaturizeNotification) { $0.miniaturizing = false }
            on(NSWindow.willCloseNotification) { $0.closing = true }
        }
        update()
    }

    /// The gate's inputs now.
    var conditions: Conditions {
        Conditions(active: isActive, reduceMotion: reduceMotion, hasWindow: window != nil,
                   windowVisible: window?.isVisible ?? false,
                   occluded: !(window?.occlusionState.contains(.visible) ?? false),
                   miniaturized: (window?.isMiniaturized ?? false) || miniaturizing, closing: closing,
                   appHidden: NSApp?.isHidden ?? false, screensAsleep: screensAsleep || sessionAway)
    }

    /// Re-evaluates now (e.g. after the owner ordered its window in).
    func update() {
        let open = Self.evaluate(conditions)
        guard open != isOpen else { return }
        isOpen = open
        onChange?(open)
    }

    /// Visible and unoccluded, Reduce Motion aside: the surface is seen (a transition may play its
    /// Reduce Motion cross-fade).
    var conditionsMet: Bool {
        let c = conditions
        return c.onScreenIgnoringOcclusion && !c.occluded
    }

    /// Visible, not miniaturized or closing, app not hidden, displays awake — but possibly covered.
    /// The permission fallback runs on this: the user is in System Settings, on top of onboarding.
    var isOnScreenIgnoringOcclusion: Bool { conditions.onScreenIgnoringOcclusion }
}
