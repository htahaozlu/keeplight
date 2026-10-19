import AppKit
import DisplayCore
import SwiftUI

/// The Settings window [v4 §5]: `NSTabViewController` in toolbar style (`.preference`), 560 wide,
/// as tall as the selected tab, ⌘1–⌘3. The window title is the tab's name, as macOS does it. A
/// closed window is let go: the next `show()` builds a fresh one (no SwiftUI tree stays alive).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: SettingsWindow?
    private var tabs: SettingsTabViewController?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Content size of `tab` below the toolbar (the render tool draws exactly this).
    static func size(for tab: SettingsTab, model: AppModel, detailsOpen: Bool = false) -> NSSize {
        let host = NSHostingView(rootView: SettingsPane(tab: tab, detailsOpen: detailsOpen).environment(model))
        return NSSize(width: SettingsMetrics.width, height: ceil(host.fittingSize.height))
    }

    /// Shows the window on `model.settingsTab`.
    func show() {
        if window == nil { makeWindow() }
        guard let window, let tabs else { return }
        tabs.select(model.settingsTab)
        if !window.isVisible {
            tabs.fitWindow(animate: false)
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.width, height: 400),
                                    styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        let tabs = SettingsTabViewController(model: model)
        window.contentViewController = tabs
        window.delegate = self
        window.onKeyEquivalent = { [weak tabs] event in tabs?.handleKeyEquivalent(event) ?? false }
        self.window = window
        self.tabs = tabs
    }

    func windowWillClose(_ notification: Notification) {
        // Next run-loop turn: AppKit is still closing the window. Detaching the toolbar and the
        // tab controller frees the panes with it.
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, !window.isVisible else { return }
            window.toolbar = nil
            window.contentViewController = nil
            self.window = nil
            self.tabs = nil
        }
    }
}

/// Window with a key-equivalent hook (⌘1–⌘3) that runs before the views see the event.
final class SettingsWindow: NSWindow {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// One SwiftUI pane per tab. Resizes the window to the selected pane's preferred size, keeping the
/// top edge in place and never growing past the screen.
final class SettingsTabViewController: NSTabViewController {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = Self.transitions
        for tab in SettingsTab.allCases {
            let pane = NSHostingController(rootView: SettingsPane(tab: tab).environment(model))
            // The pane reports its natural size; the window follows it (no Auto Layout fight).
            pane.sizingOptions = [.preferredContentSize]
            pane.title = tab.title
            let item = NSTabViewItem(viewController: pane)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Tabs switch at once and the window takes the new height at once, like System Settings:
    /// a settings window is read, not watched.
    static var transitions: NSViewController.TransitionOptions { [] }

    func select(_ tab: SettingsTab) {
        guard let index = SettingsTab.allCases.firstIndex(of: tab), selectedTabViewItemIndex != index else { return }
        selectedTabViewItemIndex = index
    }

    /// ⌘1…⌘3 select tabs.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let characters = event.charactersIgnoringModifiers,
              let digit = Int(characters), SettingsTab.allCases.indices.contains(digit - 1) else { return false }
        transitionOptions = Self.transitions
        selectedTabViewItemIndex = digit - 1
        return true
    }

    /// Reduce Motion may have changed since the last switch: read it before this one starts.
    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        transitionOptions = Self.transitions
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let tab = SettingsTab(rawValue: id), model.settingsTab != tab {
            model.settingsTab = tab
        }
        if let title = tabViewItem?.label { view.window?.title = title }
        transitionOptions = Self.transitions
        fitWindow(animate: true)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if tabViewItems.indices.contains(selectedTabViewItemIndex),
           viewController === tabViewItems[selectedTabViewItemIndex].viewController {
            fitWindow(animate: true)
        }
    }

    func fitWindow(animate: Bool) {
        guard let window = view.window, tabViewItems.indices.contains(selectedTabViewItemIndex),
              let pane = tabViewItems[selectedTabViewItemIndex].viewController else { return }
        _ = pane.view
        var size = pane.preferredContentSize
        if size.height <= 0 { size = pane.view.fittingSize }
        guard size.height > 0 else { return }
        size.width = SettingsMetrics.width
        var target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        if let screen = window.screen ?? NSScreen.main, target.height > screen.visibleFrame.height {
            size.height = screen.visibleFrame.height - (target.height - size.height)
            target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        }
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: false)
    }
}
