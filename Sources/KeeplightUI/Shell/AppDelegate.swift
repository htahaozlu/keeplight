import AppKit
import DisplayCore
import os

/// Launch order matters: pending-change recovery runs before any UI [O§7.1 step 8], then the
/// model, the shell, hotkeys and system observers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services: AppServices
    private var flags = LaunchFlags.current()
    private var engine: TransactionEngine?
    private var recovered: RevertResult?
    private var model: AppModel?
    private var shell: Shell?
    private var observers: [any NSObjectProtocol] = []

    init(services: AppServices) {
        self.services = services
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Before anything reads the state: Dotpitch's folder becomes Keeplight's (once), and its
        // per-display memory and safety settings come over from its defaults domain.
        if !flags.debug, services.directory == Keeplight.supportDirectory {
            let outcome = LegacyData.migrate()
            if outcome != .nothing { launchLog.info("legacy data: \(String(describing: outcome), privacy: .public)") }
            if services.persistentPreferences {
                let imported = DefaultsMigration.run()
                if !imported.isEmpty { launchLog.info("legacy defaults: \(imported.joined(separator: ", "), privacy: .public)") }
            }
        }
        let system = services.makeSystem(DisconnectedRegistry(directory: services.directory))
        let engine = TransactionEngine(applier: system, directory: services.directory, source: .panel)
        // Before any UI, also in safe start. Debug mode writes nothing.
        recovered = flags.debug ? nil : engine.recoverAtLaunch()
        self.engine = engine
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let engine else { return }
        let model = AppModel(flags: flags, engine: engine, recovered: recovered, services: services)
        let shell = Shell(model: model)
        self.model = model
        self.shell = shell
        installMainMenu()
        registerHotKeys(model: model, shell: shell)
        observeSystem(model: model)
        model.start()
        #if DEBUG
        DebugCapture.scheduleIfRequested(flags: flags)
        #endif
        if model.showFirstRun {
            // A moment for the first inventory and brightness probes: the pages name the displays.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                shell.showOnboarding()
            }
        } else if flags.debug || model.showSafeStart {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                shell.openPanel()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // While onboarding is open the app is in the Dock; its icon brings onboarding back.
        if shell?.isOnboardingOpen == true { shell?.showOnboarding() } else { shell?.openPanel() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.prepareToQuit()
    }

    // MARK: Hotkeys

    private func registerHotKeys(model: AppModel, shell: Shell) {
        let keys = services.hotKeys
        if !keys.register(.panel, onPress: { shell.togglePanel() }, onRelease: nil) {
            model.hotKeyFailures.append(HotKeys.Key.panel.display)
        }
        if !keys.register(.rescue, onPress: { model.beginRescueHold() }, onRelease: { model.cancelRescueHold() }) {
            model.hotKeyFailures.append(HotKeys.Key.rescue.display)
        }
    }

    // MARK: System

    /// Sleep reverts a pending change synchronously; wake starts the settle window.
    private func observeSystem(model: AppModel) {
        observers += services.systemEvents.observeSleepWake(willSleep: { model.systemWillSleep() },
                                                            didWake: { model.systemDidWake() })
    }

    // MARK: Menu (key equivalents and text editing for Settings; the app has no menu bar of its own)

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        let identify = NSMenuItem(title: "Identify Displays", action: #selector(identifyDisplays), keyEquivalent: "i")
        identify.target = self
        app.addItem(identify)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit Keeplight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    @objc private func identifyDisplays() { model?.identify() }
    @objc private func openSettings() { model?.openSettings() }
}

private let launchLog = Logger(subsystem: "io.github.htahaozlu.Keeplight", category: "launch")
