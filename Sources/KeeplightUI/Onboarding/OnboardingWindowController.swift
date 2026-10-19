import AppKit

/// The onboarding window (§4): 560 × 440, titled and closable, full-size content under a
/// transparent hidden title bar, on `paper`; on the screen with the pointer. The app is `.regular`
/// while it is open (Dock icon, Cmd-Tab: the user goes to System Settings and back) and
/// `.accessory` again after. `Done` or closing the window finishes onboarding.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let flow: OnboardingFlow
    let content: OnboardingView
    /// After the window closed (the shell releases the controller).
    var onClose: (() -> Void)?

    /// Whether a change waits for Keep (its card owns the keyboard).
    private let changePending: @MainActor () -> Bool

    init(model: AppModel) {
        changePending = { [weak model] in model?.pending != nil }
        flow = OnboardingFlow(model: model)
        content = OnboardingView(flow: flow)
        let window = OnboardingWindow(contentRect: NSRect(origin: .zero, size: OnboardingMetrics.size),
                                      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
                                      defer: true)
        window.title = OnboardingCopy.wordmark
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.backgroundColor = OnboardingTheme.dynamic(.paper)
        window.contentView = content
        super.init(window: window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.content.cancel() }
        content.onFinish = { [weak self] in self?.window?.close() }
        content.onGranted = { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            // A change waiting for Keep owns Return and Esc: come forward without taking the keyboard.
            if self.changePending() {
                window.orderFront(nil)
            } else {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// On the pointer's screen, a little above centre; the app comes forward.
    func show() {
        guard let window else { return }
        if !window.isVisible {
            let screen = NSScreen.underPointer ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(),
                                              y: (visible.minY + (visible.height - size.height) * 0.55).rounded()))
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        content.didAppear()
    }

    func windowWillClose(_ notification: Notification) {
        flow.finish(applyLogin: false)
        content.teardown()
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor [weak self] in
            // Drop the content so the scenes' layers are freed even if AppKit keeps the window a while.
            self?.window?.contentView = nil
            self?.onClose?()
        }
    }
}

/// Esc anywhere in the window goes to the page (close on pages 1–2, `Not Now` on page 3).
final class OnboardingWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
