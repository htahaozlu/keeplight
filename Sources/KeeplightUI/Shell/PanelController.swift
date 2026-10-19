import AppKit
import SwiftUI

/// The borderless, non-activating panel that behaves like a menu: it can become key (so sliders
/// and keys work) without activating the app, and closes on Esc.
final class KeeplightPanel: NSPanel {
    var onCancel: (@MainActor () -> Void)?
    var onShortcut: (@MainActor (NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityLabel("Keeplight")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A click on the panel while another window had the keyboard: become key first, so the click
    /// reaches the slider, menu or button under the pointer instead of only focusing the panel.
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            MainActor.assumeIsolated { onCancel?() }
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { onCancel?() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let handled = MainActor.assumeIsolated { onShortcut?(event) ?? false }
        return handled || super.performKeyEquivalent(with: event)
    }
}

/// Opens, positions and closes the panel.
@MainActor
final class PanelController: NSObject {
    private let model: AppModel
    private let panel: KeeplightPanel
    private let anchor: () -> NSRect?
    private let statusWindow: () -> NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var frameTask: Task<Void, Never>?
    private(set) var isOpen = false

    init(model: AppModel, anchor: @escaping () -> NSRect?, statusWindow: @escaping () -> NSWindow?) {
        self.model = model
        self.anchor = anchor
        self.statusWindow = statusWindow
        panel = KeeplightPanel(contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 200))
        super.init()
        panel.onCancel = { [weak self] in self?.close() }
        panel.onShortcut = { [weak self] event in self?.handleShortcut(event) ?? false }
        trackHeight()
    }

    var window: NSWindow { panel }

    func toggle() { isOpen ? close() : open() }

    // MARK: Open / close

    func open() {
        guard !isOpen else { return }
        isOpen = true
        model.panelDidOpen()
        frameTask?.cancel()
        installContent()
        panel.alphaValue = 1
        panel.setFrame(targetFrame(), display: true)
        panel.makeKeyAndOrderFront(nil)
        // The model stays at the resting pose (opaque); only the fade is added. A view-backed layer
        // anchors at its corner, so the timeline's scale is left out rather than shifting the panel.
        // Reduce Motion keeps a 150 ms linear fade (v5 §6).
        if let layer = panel.contentView?.layer, AnimationGate.mayAnimate(in: panel, reducedForm: true) {
            let timeline = AnimationGate.reduceMotion ? Timeline.panelOpenReduced : Timeline.panelOpen
            layer.add(timeline.animation(for: .opacity), forKey: "panel.open.opacity")
        }
        installMonitors()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        model.panelDidClose()
        panel.orderOut(nil)
        releaseContentSoon()
    }

    // MARK: Content

    /// The SwiftUI tree exists only while the panel is open; every open builds it fresh.
    private func installContent() {
        guard panel.contentView == nil else { return }
        let host = FirstClickHostingView(rootView: PanelRoot().environment(model))
        host.sizingOptions = []
        panel.contentView = PanelMaterial.container(wrapping: host)
    }

    /// One run-loop turn after closing, so a button that closed the panel from inside its own
    /// action is not torn down underneath itself. A reopen in between keeps the content.
    private func releaseContentSoon() {
        Task { @MainActor [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.contentView = nil
        }
    }

    // MARK: Geometry

    /// Panel frame under the status item (or top-centre of the screen with the pointer when it is hidden).
    private func targetFrame() -> NSRect {
        let width = Metrics.panelWidth
        let anchorRect = anchor()
        let screen = anchorRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let height = clampedHeight(visible)
        let x: CGFloat
        let top: CGFloat
        if let anchorRect {
            x = anchorRect.midX - width / 2
            top = min(anchorRect.minY, visible.maxY) - 4
        } else {
            x = visible.midX - width / 2
            top = visible.maxY - 8
        }
        let clampedX = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        return NSRect(x: clampedX, y: top - height, width: width, height: height)
    }

    private func clampedHeight(_ visible: NSRect) -> CGFloat {
        let maximum = max(240, visible.height - 80)
        model.panelMaxHeight = maximum

        return min(max(model.panelContentHeight, 80), maximum)
    }

    /// Follows the content height (hotplug, receipts) with the top edge fixed.
    private func trackHeight() {
        withObservationTracking {
            _ = model.panelContentHeight
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.resizeToContent()
                self?.trackHeight()
            }
        }
    }

    private func resizeToContent() {
        guard isOpen else { return }
        let screen = panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? panel.frame
        let height = clampedHeight(visible)
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: Monitors

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let outside = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOpen else { return false }
                // The panel's own popover (No brightness control) is part of the panel.
                let inside = event.window.map { $0 === self.panel || $0.parent === self.panel
                    || self.panel.childWindows?.contains($0) == true } ?? false
                return !inside && event.window !== self.statusWindow()
            }
            if outside { Task { @MainActor in self?.close() } }
            return event
        }
    }

    private func removeMonitors() {
        for monitor in [globalMonitor, localMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalMonitor = nil
        localMonitor = nil
    }

    // MARK: Keys

    /// ⌘Z undo, ⌘I identify, ⌘, settings, ⌘Q quit.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "z":
            if model.pending == nil { model.undo() }
        case "i":
            model.identify()
        case ",":
            model.openSettings()
        case "q":
            NSApp.terminate(nil)
        case "w":
            close()
        default:
            return false
        }
        return true
    }
}

/// The panel never activates the app, so after focus moved elsewhere (a menu, the Keep card,
/// another app) AppKit would spend the first click on making the panel key and the control under
/// the pointer would not react. Every click counts here, like in a menu.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
