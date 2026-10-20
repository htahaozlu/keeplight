import AppKit
import DisplayCore
import os
import SwiftUI

/// What the model asks of the AppKit shell.
@MainActor
protocol ShellActions: AnyObject {
    func openPanel()
    func closePanel()
    func togglePanel()
    func showRing()
    func dismissRing(animated: Bool)
    func identify()
    func showSettings()
    func showBrightnessOSD(on id: CGDirectDisplayID, value: Double)
    func syncRing()
    func rescueHUD(_ phase: RescueHUDPhase)
}

/// App state and actions. Every display change goes through `DisplayCore`: risky ones through
/// `TransactionEngine`, brightness through `BrightnessWriter` and the journal coalescer.
@MainActor @Observable
final class AppModel {
    // MARK: Dependencies

    let flags: LaunchFlags
    let prefs: Preferences
    let engine: TransactionEngine
    let journal: Journal
    let registry: DisconnectedRegistry
    let knownGood: KnownGoodStore
    let system: any AppDisplaySystem
    let rescue: Rescue
    @ObservationIgnored let services: AppServices
    @ObservationIgnored weak var shell: ShellActions?

    // MARK: Inventory

    /// Active displays and online mirror targets, in map order.
    var items: [DisplayItem] = []
    /// Displays Keeplight disconnected.
    var disconnected: [DisconnectedDisplay] = []
    var brightness: [CGDirectDisplayID: BrightnessState] = [:]

    // MARK: Transactions, journal, receipts

    /// The live change (disables the panel's sections, status item ` Keep?`). Cleared the moment it
    /// is kept or reverted.
    var pending: PendingInfo? {
        didSet { if pending?.id != oldValue?.id { watchPending() } }
    }
    /// What the Keep card shows; outlives `pending` through the Kept / Reverted resolution.
    var ringInfo: PendingInfo?
    var ringPhase: RingPhase = .live
    var receipt: Receipt?
    var undoCandidate: UndoCandidate?
    var isSettling = false
    var hotKeyFailures: [String] = []
    /// The brightness-key tap is installed (setting on and Accessibility granted).
    var brightnessKeysActive = false
    @ObservationIgnored var brightnessKeys: (any BrightnessKeyTap)!
    /// The Accessibility prompt was shown this run (shown at most once per launch).
    var diagnoses: [String: DiagnosisState] = [:]
    var passports: [String: Passport] = [:]
    var launchAtLogin: Bool
    var errorMessage: String?
    /// Short-lived caption under the sections.
    var notice: String?

    // MARK: Panel UI state

    /// Displays whose "No brightness control" popover is open.
    var whyExpanded: Set<CGDirectDisplayID> = []
    var copied: String?
    var showSafeStart: Bool
    var showFirstRun: Bool
    /// The first-run page on screen (`AppModel+Onboarding`).
    var onboardingStep = OnboardingStep.welcome
    var isPanelOpen = false
    var panelMaxHeight: CGFloat = 720
    /// Natural height of the panel content; the shell sizes the panel to it.
    var panelContentHeight: CGFloat = 240
    var settingsTab: SettingsTab = .general
    var settingsSelection: String?

    // MARK: Internals

    @ObservationIgnored var token: AnyObject?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var knownIDs: Set<CGDirectDisplayID> = []
    #if DEBUG
    /// Debug previews show a synthetic desk; inventory refreshes leave it alone.
    @ObservationIgnored var fakeDisplays = false
    /// A synthetic journal for debug previews (no Settings tab reads it since v4).
    @ObservationIgnored var debugJournal: [JournalEntry] = []
    #endif
    @ObservationIgnored var probeTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    /// Fingerprints whose brightness may be restored once the next probe reads a value (after wake).
    @ObservationIgnored var pendingRestore: Set<String> = []
    @ObservationIgnored var nativeCache: [String: PixelSize] = [:]
    @ObservationIgnored var physicalCache: [CGDirectDisplayID: Bool] = [:]
    @ObservationIgnored let writer = BrightnessWriter()
    @ObservationIgnored var coalescer = BrightnessGestureCoalescer()
    @ObservationIgnored var gestureTask: Task<Void, Never>?
    @ObservationIgnored var dragging: Set<CGDirectDisplayID> = []
    @ObservationIgnored var lastBrightnessWrite: [CGDirectDisplayID: Date] = [:]
    @ObservationIgnored var deadlineTask: Task<Void, Never>?
    @ObservationIgnored var receiptTask: Task<Void, Never>?
    @ObservationIgnored var noticeTask: Task<Void, Never>?
    @ObservationIgnored var copiedTask: Task<Void, Never>?
    @ObservationIgnored var knownGoodTask: Task<Void, Never>?
    @ObservationIgnored var autoRescueTask: Task<Void, Never>?
    @ObservationIgnored var pendingCheckTask: Task<Void, Never>?
    @ObservationIgnored var rescueHoldTask: Task<Void, Never>?
    @ObservationIgnored var settleTask: Task<Void, Never>?
    @ObservationIgnored var settle: SettleWindow?
    @ObservationIgnored var restoreAfterSettle = false
    @ObservationIgnored var lastWake: Date?
    /// From `willSleep` until the wake settle window ends: no auto-rescue, no known-good saves.
    @ObservationIgnored var asleep = false
    /// The other display a main / unmirror change was made against (previous main, mirror
    /// source), by transaction id and then by its kept journal entry id; Undo resolves it by
    /// fingerprint.
    @ObservationIgnored var undoCounterparts: [String: String] = [:]
    /// Set once a known-good setup has been saved this run; until then foreign
    /// reconfigurations restart the 30 s launch save instead of cancelling it.
    @ObservationIgnored var launchKnownGoodSaved = false
    /// Keep ignores input until this long after the card appears.
    static let keepArmDelay: TimeInterval = 0.8
    /// System uptime when Keep starts accepting input (card shown + `keepArmDelay`).
    @ObservationIgnored var keepArmedAt = TimeInterval.infinity
    /// System uptime when the card appeared; Return events from before it (queued while a mode
    /// change blocked) are dropped.
    @ObservationIgnored var ringShownUptime: TimeInterval = .infinity
    @ObservationIgnored var previousApp: NSRunningApplication?
    /// The last rescue's journal entries and the setup before it (Undo restores it as a whole).
    @ObservationIgnored var rescueGroup: (ids: Set<String>, before: DisplaySnapshot)?
    /// Rescue entries undone together with the one a kept restore names.
    @ObservationIgnored var appUndone: Set<String> = []
    @ObservationIgnored var sessionNew: Set<String> = []
    /// Erase All Keeplight Data ran: nothing is written to preferences, the journal or known-good
    /// setups again until the next launch.
    @ObservationIgnored private(set) var erased = false
    /// At most one brightness error row per 10 s.
    @ObservationIgnored var errorLimiter = ErrorRateLimiter()
    /// The row currently (or last) shown is a brightness write failure; the next good write clears it.
    @ObservationIgnored var brightnessErrorShown = false
    /// Apple panels already raised to the sole-screen floor in this stretch of being the only display.
    @ObservationIgnored var floorClamped: Set<CGDirectDisplayID> = []
    /// Our own reconfigurations until this time don't count as hotplug.
    @ObservationIgnored var ownChangeUntil = Date.distantPast
    @ObservationIgnored var recovered: RevertResult?
    /// False in safe start (until Continue) and in debug mode: no wake restore, no known-good writes.
    @ObservationIgnored var automaticChangesAllowed: Bool

    init(flags: LaunchFlags, engine: TransactionEngine, recovered: RevertResult?, services: AppServices) {
        self.flags = flags
        self.engine = engine
        self.recovered = recovered
        self.services = services
        journal = engine.journal
        registry = engine.registry
        launchAtLogin = services.loginItem.isEnabled
        let system = services.makeSystem(engine.registry)
        let knownGood = KnownGoodStore(directory: engine.directory)
        self.system = system
        self.knownGood = knownGood
        rescue = Rescue(system: system, engine: engine, registry: engine.registry, mirrors: engine.mirrors,
                        knownGood: knownGood, journal: engine.journal)
        let prefs = Preferences(persistent: services.persistentPreferences && !flags.debug)
        self.prefs = prefs
        showSafeStart = flags.safeStart
        showFirstRun = !flags.debug && !flags.safeStart && prefs.onboardingVersion < OnboardingFlow.version
        automaticChangesAllowed = !flags.debug && !flags.safeStart
        brightnessKeys = services.makeBrightnessKeys({ [weak self] in self?.prefs.functionKeysAsBrightness ?? false }) {
            [weak self] up, fine in self?.handleBrightnessKey(up: up, fine: fine) ?? false
        }
        brightnessKeys.onChange = { [weak self] in
            guard let self else { return }
            self.brightnessKeysActive = self.brightnessKeys.isRunning
        }
        prefs.onFunctionKeysChange = { [weak self] in self?.brightnessKeys.functionKeysChanged() }
    }

    /// Called once the shell exists.
    func start() {
        token = system.observeReconfiguration { [weak self] in
            Task { @MainActor in self?.reconfigured() }
        }
        #if DEBUG
        if flags.debug, flags.debugStates["fake"] != nil { installFakeDisplays() }
        #endif
        refresh()
        if let recovered, recovered.entry != nil {
            let t = recovered.transaction
            let info = PendingInfo(id: t.id, kind: t.kind, displayName: t.displayName,
                                   title: OverlayCopy.keepTitle(t.kind, name: t.displayName, summary: t.summary),
                                   detail: t.summary, displayFingerprint: t.displayFingerprint, before: t.before,
                                   startedAt: t.startedAt, deadline: t.deadline)
            if let text = Copy.revertReceipt(info, reason: .appRelaunch) { showReceipt(text) }
        }
        scheduleKnownGoodSave(after: 30)
        scheduleAutoRescueCheck()
        syncBrightnessKeys()
        #if DEBUG
        if flags.debug { applyDebugStates() }
        #endif
    }

    // MARK: Inventory

    func refresh() {
        #if DEBUG
        if fakeDisplays { return }
        #endif
        syncPendingAfterExternalRevert()
        let online = system.displays()
        acceptReconnectedByMacOS(online)
        disconnected = registry.load()
        // Mirror targets can report inactive (hardware mirroring) but still need a plate.
        let shown = online.filter { $0.isActive || ($0.isOnline && $0.isMirrorTarget) }
        let order = DeskLayout.order(shown.map { (id: $0.id, bounds: $0.bounds) })
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let firstSighting = prefs.knownDisplays.isEmpty
        var fresh: [DisplayItem] = []
        for (offset, id) in order.enumerated() {
            guard let info = byID[id] else { continue }
            let fp = info.fingerprint
            if prefs.knownDisplays[fp] == nil, !firstSighting { sessionNew.insert(fp) }
            if prefs.knownDisplays[fp] != info.name { prefs.knownDisplays[fp] = info.name }
            let native = nativeCache[fp] ?? system.nativePixelSize(for: id).map(PixelSize.init)
            if let native { nativeCache[fp] = native }
            let physical = physicalCache[id] ?? system.isPhysical(id)
            physicalCache[id] = physical
            fresh.append(DisplayItem(info: info, index: offset + 1, modes: system.modes(for: id), native: native,
                                     isPhysical: physical, isNew: sessionNew.contains(fp)))
        }
        if fresh != items {
            items = fresh
        }

        let ids = Set(fresh.map(\.id))
        if ids != knownIDs {
            let added = fresh.filter { !knownIDs.contains($0.id) }.map(\.info)
            let firstInventory = knownIDs.isEmpty
            knownIDs = ids
            brightness = brightness.filter { ids.contains($0.key) }
            physicalCache = physicalCache.filter { ids.contains($0.key) }
            if firstInventory || Date() < ownChangeUntil {
                probeBrightness(added)
            } else if isSettling {
                noteSettleEvent()
            } else {
                beginSettling(wake: false)
            }
        }
        checkPendingTarget(online)
        enforceBrightnessFloor()
        refreshUndo()
    }

    func isPhysical(_ id: CGDirectDisplayID) -> Bool {
        if let known = physicalCache[id] { return known }
        let physical = system.isPhysical(id)
        physicalCache[id] = physical
        return physical
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func item(_ id: CGDirectDisplayID) -> DisplayItem? { items.first { $0.id == id } }

    /// Nickname if set, else the display's own name.
    func name(_ info: DisplayInfo) -> String { prefs.nickname(for: info.fingerprint) ?? info.name }

    func name(fingerprint: String, fallback: String) -> String { prefs.nickname(for: fingerprint) ?? fallback }

    func ref(_ info: DisplayInfo) -> DisplayRef { DisplayRef(name: name(info), fp: info.fingerprint) }

    var isOnlyActive: Bool { items.count == 1 }

    /// Another physical display stays active after disconnecting `item`.
    func canDisconnect(_ item: DisplayItem) -> Bool {
        items.contains { $0.id != item.id && $0.isPhysical && !$0.info.isMirrorTarget }
    }

    /// Selector the CLI resolves to this display: its name when unique, else `id:N`. The name comes
    /// from the monitor's EDID, so it is single-quoted for the shell (an embedded `'` becomes
    /// `'\''`): pasting the copied command must never run `$(…)` or backticks hidden in a name.
    func cliSelector(_ info: DisplayInfo) -> String {
        let needle = info.name.lowercased()
        let matches = items.filter { $0.info.name.lowercased().contains(needle) }
        return matches.count == 1 ? Self.shellQuoted(info.name) : "id:\(info.id)"
    }

    /// `text` as one POSIX shell word.
    nonisolated static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func markOwnChange(_ seconds: TimeInterval = 3) {
        ownChangeUntil = Date().addingTimeInterval(seconds)
    }

    // MARK: Journal and undo candidate

    /// Writes one journal entry made by the model itself (not the engine or Rescue), unless the
    /// data was erased or this is a read-only run.
    func record(_ entry: JournalEntry) {
        guard !erased, !flags.readOnly else { return }
        try? journal.append(entry)
    }

    /// After every journal append: the Undo candidate may have changed.
    func journalChanged() {
        refreshUndo()
    }

    func refreshUndo() {
        guard let entry = latestUndoable() else {
            if undoCandidate != nil { undoCandidate = nil }
            return
        }
        let candidate = UndoCandidate(entry: entry, label: undoLabel(entry))
        if candidate != undoCandidate { undoCandidate = candidate }
    }

    func undoLabel(_ entry: JournalEntry) -> String {
        if entry.source == .rescue, rescueGroup?.ids.contains(entry.id) == true { return "Undo Rescue" }
        return "Undo " + Copy.change(entry) + (entry.display.map { " on \($0.name)" } ?? "")
    }

    // MARK: Feedback

    func showReceipt(_ text: String, undo: Receipt.Undo? = nil) {
        receipt = Receipt(text: text, undo: undo, expires: Date().addingTimeInterval(60))
        receiptTask?.cancel()
        receiptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.receipt = nil
        }
    }

    func flashNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// The error row shows a fixed sentence; what the system said goes to the log.
    func report(_ error: Error) {
        modelLog.error("\(String(describing: error), privacy: .public)")
        errorMessage = PanelError.sentence(for: error)
    }

    func copy(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = key
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.copied = nil
        }
    }

    func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Panel

    func panelDidOpen() {
        isPanelOpen = true
        refresh()
        reloadBrightness()
        syncBrightnessKeys()
    }

    func panelDidClose() {
        isPanelOpen = false
        whyExpanded = []
        finishGestures()
    }

    func toggleWhy(_ item: DisplayItem) {
        if whyExpanded.contains(item.id) { whyExpanded.remove(item.id) } else { whyExpanded.insert(item.id) }
        if diagnoses[item.fingerprint]?.report == nil { diagnose(item.fingerprint) }
    }

    /// `···` › Copy Command: the CLI line that does what the slider does now.
    func copyCommand(_ item: DisplayItem) {
        guard let value = brightness[item.id]?.value ?? prefs.lastWritten[item.fingerprint]?.value else { return }
        copy("keeplight brightness \(cliSelector(item.info)) \(BrightnessPolicy.percent(value))",
             key: "cmd:\(item.id)")
    }

    func identify() { shell?.identify() }

    func openSettings(tab: SettingsTab? = nil, selecting fingerprint: String? = nil) {
        if let tab { settingsTab = tab }
        if let fingerprint { settingsSelection = fingerprint }
        shell?.closePanel()
        shell?.showSettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !flags.readOnly else { return flashNotice("Debug mode: settings aren't saved.") }
        if let detail = services.loginItem.set(enabled) {
            modelLog.error("login item: \(detail, privacy: .public)")
            errorMessage = PanelError.loginItem
        }
        launchAtLogin = services.loginItem.isEnabled
    }

    func finishFirstRun() {
        if !flags.readOnly { prefs.onboardingVersion = OnboardingFlow.version }
        showFirstRun = false
    }

    func safeStartContinue() {
        endSafeStart()
        scheduleKnownGoodSave(after: 30)
    }

    /// A rescued setup is never saved as known-good by itself.
    func safeStartRescue() {
        runRescue()
        endSafeStart()
    }

    private func endSafeStart() {
        showSafeStart = false
        automaticChangesAllowed = !flags.debug
        scheduleAutoRescueCheck()
    }

    /// Erase All Keeplight Data: reconnect what we disconnected, then delete everything on disk.
    func eraseAllData() {
        guard !flags.readOnly else { return }
        if pending != nil { revertPending(.user) }
        finishGestures()
        registry.reconnectAll()
        knownGoodTask?.cancel()
        try? FileManager.default.removeItem(at: engine.directory)
        services.dimmer.resetAll()
        prefs.eraseAll()
        // Brightness keys are off again: the tap goes too, not only the setting.
        brightnessKeys.stop()
        brightnessKeysActive = brightnessKeys.isRunning
        erased = true
        undoCandidate = nil
        receipt = nil
        journalChanged()
        showReceipt("Erased all Keeplight data.")
        scheduleRefresh()
    }

    /// Before quitting: finish the journal, revert a pending change, reconnect what we disconnected.
    func prepareToQuit() {
        finishGestures()
        // macOS restores the tables at exit anyway; this keeps it explicit and immediate.
        services.dimmer.resetAll()
        // Debug mode's pending card is a preview; reverting would restore a real pending.json.
        if pending != nil, !flags.readOnly { _ = try? engine.revert(reason: .user) }
        pending = nil
        guard !flags.readOnly else { return }
        // One journaled reconnect per display, like the panel's Reconnect.
        let direct = DirectChange(applier: system, journal: journal, registry: registry, mirrors: engine.mirrors,
                                  source: .panel)
        for display in registry.load() {
            _ = try? direct.apply(.reconnect, display: display.ref, displayID: display.displayID) {
                try system.setEnabled(true, for: display.displayID, option: .forSession)
            }
        }
        prefs.saveLastWritten()
    }
}

let modelLog = Logger(subsystem: "io.github.htahaozlu.Keeplight", category: "model")
