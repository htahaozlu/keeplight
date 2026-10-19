import AppKit

/// The menu bar item: `StatusGlyph` as a template, plus the title ` Keep?` while a change waits
/// for an answer. Left click toggles the panel (or, while pending, makes the Keep card
/// key); right click / ⌃-click opens a small `NSMenu`.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item: NSStatusItem
    private let onToggle: () -> Void
    private var shownPending: Bool?
    private var contrastObserver: (any NSObjectProtocol)?

    static let pendingTitle = " Keep?"

    init(model: AppModel, onToggle: @escaping () -> Void) {
        self.model = model
        self.onToggle = onToggle
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "keeplight.status"
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.image = Self.icon
            button.imagePosition = .imageOnly
        }
        track()
        // Increase Contrast thickens the glyph's line: redraw when it changes.
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shownPending = nil
                self?.apply()
            }
        }
    }

    /// The button's frame in screen coordinates; nil when the item is hidden.
    var anchorRect: NSRect? {
        guard item.isVisible, let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    var window: NSWindow? { item.button?.window }

    // MARK: State

    /// The idle glyph (template; the menu bar tints it).
    static var icon: NSImage { StatusGlyph.image(pending: false) }

    static func accessibilityLabel(pending: Bool) -> String { pending ? "Keeplight, keep change?" : "Keeplight" }

    private func apply() {
        item.isVisible = model.prefs.showInMenuBar
        let pending = model.pending != nil
        guard shownPending != pending, let button = item.button else { return }
        shownPending = pending
        button.image = StatusGlyph.image(pending: pending)
        button.title = pending ? Self.pendingTitle : ""
        button.imagePosition = pending ? .imageLeading : .imageOnly
        button.setAccessibilityLabel(Self.accessibilityLabel(pending: pending))
    }

    private func track() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if model.pending != nil {
            focusKeepCard()
        } else {
            onToggle()
        }
    }

    /// While a change is pending the decision lives on the Keep card: bring it forward.
    private func focusKeepCard() {
        let cards = NSApp.windows.filter {
            $0.isVisible && $0.canBecomeKey && $0.level > .normal && $0 !== window && !($0 is KeeplightPanel)
        }
        let pointer = NSEvent.mouseLocation
        let card = cards.first { NSMouseInRect(pointer, $0.screen?.frame ?? .zero, false) } ?? cards.first
        NSApp.activate()
        card?.makeKeyAndOrderFront(nil)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let candidate = model.undoCandidate, model.pending == nil {
            menu.addItem(ClosureMenuItem(candidate.label) { [model] in model.undo() })
        } else {
            menu.addItem(ClosureMenuItem("Undo", enabled: false) {})
        }
        let identify = ClosureMenuItem("Identify Displays") { [model] in model.identify() }
        identify.keyEquivalent = "i"
        menu.addItem(identify)
        let settings = ClosureMenuItem("Settings…") { [model] in model.openSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = ClosureMenuItem("Quit Keeplight") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}
