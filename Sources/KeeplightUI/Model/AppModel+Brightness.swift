import AppKit
import DisplayCore

/// Brightness: probing, reading, throttled writes and one journal entry per gesture [O§5.1].
extension AppModel {
    enum ProbeResult: Sendable {
        case none
        case found(any BrightnessControl, Double?, Int)
    }

    // MARK: Probing

    /// Finds the brightness backend of each display and reads its level, off the main thread.
    /// Displays that answer nothing are retried with the settle back-off (0 / 0.5 / 1 / 2 s) before
    /// they are called unavailable.
    func probeBrightness(_ infos: [DisplayInfo]) {
        for info in infos { startProbe(info) }
    }

    func cancelProbes() {
        for task in probeTasks.values { task.cancel() }
        probeTasks = [:]
    }

    private func startProbe(_ info: DisplayInfo) {
        probeTasks[info.id]?.cancel()
        if brightness[info.id] == nil { brightness[info.id] = .probing }
        let physical = physicalCache[info.id] ?? system.isPhysical(info.id)
        let delays: [TimeInterval] = physical ? SettleWindow.probeBackoff : [0]
        let system = self.system
        probeTasks[info.id] = Task { [weak self] in
            for (attempt, delay) in delays.enumerated() {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                if Task.isCancelled { return }
                let result = await Task.detached(priority: .userInitiated) { Self.probe(info, on: system) }.value
                if Task.isCancelled { return }
                guard let self else { return }
                if case .found(let control, let value, let ms) = result {
                    self.brightness[info.id] = .available(control: control, value: value, readMs: ms)
                    self.probeSucceeded(info, control: control, value: value)
                    self.enforceBrightnessFloor()
                    self.probeFinished(info)
                    return
                }
                if attempt == delays.count - 1 {
                    self.brightness[info.id] = .unavailable
                    self.probeFinished(info)
                }
            }
        }
    }

    /// Every final probe outcome (value, no value, no control) ends the display's wake-restore
    /// chance; the post-wake cycle ends when no probe is left.
    private func probeFinished(_ info: DisplayInfo) {
        probeTasks[info.id] = nil
        pendingRestore.remove(info.fingerprint)
        if probeTasks.isEmpty, !isSettling { pendingRestore = [] }
    }

    nonisolated static func probe(_ info: DisplayInfo, on system: any AppDisplaySystem) -> ProbeResult {
        guard let control = system.brightnessControl(for: info) else { return .none }
        let start = ContinuousClock.now
        let value = try? control.brightness()
        return .found(control, value, Format.ms(since: start))
    }

    private func probeSucceeded(_ info: DisplayInfo, control: any BrightnessControl, value: Double?) {
        let fp = info.fingerprint
        // A level saved on the monitor's own 0…1 (before the dimmed range, or by Dotpitch): move it
        // onto the range this control speaks, or the wake restore would land far too dark.
        if control is DimmingBrightness, var last = prefs.lastWritten[fp], last.combined != true {
            last.value = DimmingCurve.fromHardware(last.value)
            last.combined = true
            prefs.lastWritten[fp] = last
        }
        guard let value else { return }
        if prefs.lastWritten[fp] == nil { prefs.lastWritten[fp] = LastWritten(value: value, date: Date()) }
        guard pendingRestore.contains(fp), control.backend == .ddc, automaticChangesAllowed,
              prefs.restoreAfterWake, let last = prefs.lastWritten[fp],
              WakeRestorePolicy.shouldRestore(read: value, lastWritten: last.value, writtenAt: last.date,
                                              now: Date())
        else { return }
        restoreBrightness(info, control: control, read: value, target: last.value)
    }

    /// Re-reads every level (panel open, after Check Again). Skips displays being written to.
    func reloadBrightness() {
        guard !isSettling else { return }
        for item in items {
            guard case .available(let control, _, _) = brightness[item.id] else { continue }
            if dragging.contains(item.id) { continue }
            if let last = lastBrightnessWrite[item.id], Date().timeIntervalSince(last) < 1.5 { continue }
            let id = item.id
            let fp = item.fingerprint
            Task { [weak self] in
                let start = ContinuousClock.now
                let value = await Task.detached(priority: .userInitiated) { try? control.brightness() }.value
                guard let self, let value, !self.isSettling, !self.dragging.contains(id),
                      case .available(let current, let old, _) = self.brightness[id] else { return }
                let ms = Format.ms(since: start)
                if old == nil || abs(BrightnessPolicy.percent(old ?? 0) - BrightnessPolicy.percent(value)) > 0 {
                    self.brightness[id] = .available(control: current, value: value, readMs: ms)
                }
                // The monitor's own buttons: remember what it shows now.
                if current.backend == .ddc, self.automaticChangesAllowed, self.pendingRestore.isEmpty {
                    let last = self.prefs.lastWritten[fp]?.value
                    if last == nil || abs(BrightnessPolicy.percent(last ?? 0) - BrightnessPolicy.percent(value)) > 2 {
                        self.prefs.lastWritten[fp] = LastWritten(value: value, date: Date())
                    }
                }
            }
        }
    }

    // MARK: Writing

    /// A brightness write from the slider, scroll, keys or Undo. Writes through the throttle
    /// (Apple ≤ 16 ms, DDC ≤ 100 ms, trailing value always written) and records one journal
    /// entry per gesture.
    func setBrightness(_ id: CGDirectDisplayID, to requested: Double) {
        guard !flags.readOnly else { return flashNotice("Debug mode: nothing is written.") }
        guard !isSettling, let item = item(id),
              case .available(let control, let old, let ms) = brightness[id] else { return }
        let value = BrightnessPolicy.clamp(requested, floor: brightnessFloor(for: id))
        let now = Date()
        let before = old ?? prefs.lastWritten[item.fingerprint]?.value ?? value
        if old == value { return }
        brightness[id] = .available(control: control, value: value, readMs: ms)
        lastBrightnessWrite[id] = now
        prefs.lastWritten[item.fingerprint] = LastWritten(value: value, date: now)
        writeBrightness(value, via: control)
        let finished = coalescer.record(ref(item.info), from: before, to: value,
                                        mechanism: control.mechanism, at: now)
        append(finished)
        scheduleGestureFlush()
    }

    /// One throttled hardware write. A failure shows one fixed sentence (at most every 10 s) and
    /// logs the detail; the next write that succeeds takes the sentence away again.
    func writeBrightness(_ value: Double, via control: any BrightnessControl) {
        let onError: @Sendable (String) -> Void = { [weak self] detail in
            Task { @MainActor in self?.brightnessWriteFailed(detail: detail) }
        }
        var onSuccess: (@Sendable () -> Void)?
        if brightnessErrorShown {
            onSuccess = { [weak self] in Task { @MainActor in self?.brightnessWriteSucceeded() } }
        }
        writer.set(value, via: control, onError: onError, onSuccess: onSuccess)
    }

    func brightnessWriteFailed(detail: String, at now: Date = Date()) {
        modelLog.error("brightness write failed: \(detail, privacy: .public)")
        guard errorLimiter.allow(at: now) else { return }
        errorMessage = PanelError.brightness
        brightnessErrorShown = true
    }

    func brightnessWriteSucceeded() {
        guard brightnessErrorShown else { return }
        brightnessErrorShown = false
        if errorMessage == PanelError.brightness { errorMessage = nil }
    }

    /// An Apple panel that becomes the only active display below 2 % (its backlight could be off,
    /// e.g. the external screen it was dimmed next to was unplugged) is raised to 2 % once, and
    /// the change is journaled. Choosing 0 on purpose stays possible, as in macOS.
    func enforceBrightnessFloor() {
        guard !flags.readOnly, !erased, !isSettling else { return }
        guard isOnlyActive, let item = items.first else {
            floorClamped = []
            return
        }
        let id = item.id
        guard !floorClamped.contains(id), case .available(let control, let value, let ms) = brightness[id],
              control.backend == .apple,
              let target = BrightnessFloor.clampTarget(value: value, floor: BrightnessPolicy.onlyScreenFloor)
        else { return }
        floorClamped.insert(id)
        brightness[id] = .available(control: control, value: target, readMs: ms)
        let now = Date()
        lastBrightnessWrite[id] = now
        prefs.lastWritten[item.fingerprint] = LastWritten(value: target, date: now)
        writeBrightness(target, via: control)
        record(JournalEntry(t: now, source: .panel, display: ref(item.info), kind: .brightness,
                            before: "\(BrightnessPolicy.percent(value ?? 0))%",
                            after: "\(BrightnessPolicy.percent(target))%", mechanism: control.mechanism,
                            result: .applied, reason: "only screen: 2 % floor"))
        journalChanged()
    }

    /// Lowest level the slider, the keys and Undo set: 0, as in macOS — a Mac screen's backlight
    /// goes off, a DDC monitor goes black through its gamma table. The brightness keys bring
    /// either back; quitting Keeplight or rescue restores the gamma.
    func brightnessFloor(for id: CGDirectDisplayID) -> Double { 0 }

    func beginDrag(_ id: CGDirectDisplayID) { dragging.insert(id) }

    func endDrag(_ id: CGDirectDisplayID) {
        dragging.remove(id)
        scheduleGestureFlush()
    }

    // MARK: Journal

    private func append(_ gestures: [BrightnessGestureCoalescer.Gesture]) {
        guard !gestures.isEmpty, !flags.readOnly, !erased else { return }
        for gesture in gestures { record(gesture.entry(source: .panel)) }
        journalChanged()
    }

    private func scheduleGestureFlush() {
        gestureTask?.cancel()
        gestureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            self.append(self.coalescer.flush(at: Date()))
        }
    }

    /// Closes every open gesture (panel closed, quit, sleep, Undo).
    func finishGestures() {
        gestureTask?.cancel()
        append(coalescer.finishAll())
    }

    // MARK: Restore after wake [O§7.6]

    /// One write, one read-back, never a retry.
    private func restoreBrightness(_ info: DisplayInfo, control: any BrightnessControl, read: Double, target: Double) {
        let display = self.ref(info)
        let id = info.id
        // Keeps `reloadBrightness` from recording the pre-restore level mid-write.
        lastBrightnessWrite[id] = Date()
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> (Double?, String?) in
                do {
                    try control.setBrightness(target)
                    try? await Task.sleep(for: .milliseconds(300))
                    return (try? control.brightness(), nil)
                } catch {
                    return (nil, String(describing: error))
                }
            }.value
            guard let self else { return }
            let readPercent = BrightnessPolicy.percent(read)
            let targetPercent = BrightnessPolicy.percent(target)
            var entry = JournalEntry(source: .wake, display: display, kind: .brightness, before: "\(readPercent)%",
                                     after: "\(targetPercent)%", mechanism: control.mechanism,
                                     result: .restored, reason: "monitor reported \(readPercent) after wake")
            if let error = outcome.1 {
                entry.result = .failed
                entry.detail = error
            } else if let back = outcome.0, abs(BrightnessPolicy.percent(back) - targetPercent) > WakeRestorePolicy.tolerancePercent {
                entry.result = .failed
                entry.detail = "monitor reads \(BrightnessPolicy.percent(back)) after the write"
            }
            self.record(entry)
            if entry.result == .restored {
                if case .available(let current, _, let ms) = self.brightness[id] {
                    self.brightness[id] = .available(control: current, value: target, readMs: ms)
                }
                self.showReceipt(Copy.wakeReceipt(name: display.name, percent: targetPercent), undo: .entry(entry.id))
            }
            self.journalChanged()
        }
    }
}
