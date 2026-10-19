import CoreGraphics
import Foundation

/// Everything rescue needs from the display system; `LiveDisplaySystem` in production.
public protocol DisplaySystem: DisplayApplier {
    func displays() -> [DisplayInfo]
    func modes(for id: CGDirectDisplayID) -> [DisplayMode]
    func nativePixelSize(for id: CGDirectDisplayID) -> (width: Int, height: Int)?
    func isPhysical(_ id: CGDirectDisplayID) -> Bool
    func setEnabled(_ enabled: Bool, for id: CGDirectDisplayID, option: CGConfigureOption) throws
    func setMain(_ id: CGDirectDisplayID, option: CGConfigureOption) throws
    func setMode(_ modeNumber: Int32, for id: CGDirectDisplayID, option: CGConfigureOption) throws
    func unmirror(_ id: CGDirectDisplayID, option: CGConfigureOption) throws
}

/// `DisplayManager` behind the `DisplaySystem` protocol.
public struct LiveDisplaySystem: DisplaySystem {
    public let registry: DisconnectedRegistry

    public init(registry: DisconnectedRegistry = .standard) {
        self.registry = registry
    }

    public func snapshot() -> DisplaySnapshot { DisplayManager.snapshot(disconnected: registry.load()) }

    public func restore(_ snapshot: DisplaySnapshot, option: CGConfigureOption) -> [RestoreStep] {
        DisplayManager.restore(snapshot, option: option, disconnected: registry.load())
    }

    public func displays() -> [DisplayInfo] { DisplayManager.displays() }
    public func modes(for id: CGDirectDisplayID) -> [DisplayMode] { DisplayManager.modes(for: id) }
    public func nativePixelSize(for id: CGDirectDisplayID) -> (width: Int, height: Int)? {
        DisplayManager.nativePixelSize(for: id)
    }
    public func isPhysical(_ id: CGDirectDisplayID) -> Bool { DisplayManager.isPhysical(id) }

    public func setEnabled(_ enabled: Bool, for id: CGDirectDisplayID, option: CGConfigureOption) throws {
        try DisplayManager.setEnabled(enabled, for: id, option: option)
    }

    public func setMain(_ id: CGDirectDisplayID, option: CGConfigureOption) throws {
        try DisplayManager.setMain(id, option: option)
    }

    public func setMode(_ modeNumber: Int32, for id: CGDirectDisplayID, option: CGConfigureOption) throws {
        try DisplayManager.setMode(modeNumber, for: id, option: option)
    }

    public func unmirror(_ id: CGDirectDisplayID, option: CGConfigureOption) throws {
        try DisplayManager.unmirror(id, option: option)
    }
}

/// One rescue step [O§7.3], in execution order.
public enum RescueStep: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Why a fallback mode was chosen.
    public enum ModeChoice: String, Codable, Sendable {
        /// Mode flag 0x4.
        case systemDefault = "default"
        case largestCrisp = "crisp"
        case native
    }

    case revertPending(PendingTransaction)
    case reconnect(DisplayRef, displayID: CGDirectDisplayID)
    case stopMirroring(DisplayRef, displayID: CGDirectDisplayID)
    case applyKnownGood(DisplaySnapshot, actions: [RestoreAction])
    case makeMain(DisplayRef, displayID: CGDirectDisplayID)
    case setMode(DisplayRef, displayID: CGDirectDisplayID, from: String?, to: DisplayMode, choice: ModeChoice)

    public var description: String {
        switch self {
        case .revertPending(let t): "Revert the pending \(t.kind.rawValue) change on \(t.display.name) (\(t.after) → \(t.before))"
        case .reconnect(let d, let id): "Reconnect \(d.name) (id \(id))"
        case .stopMirroring(let d, _): "Stop mirroring on \(d.name)"
        case .applyKnownGood(let s, let actions):
            "Restore the last kept setup for these displays (saved \(Self.format(s.takenAt))): "
                + actions.map(\.description).joined(separator: ", ")
        case .makeMain(let d, _): "Make \(d.name) the main display"
        case .setMode(let d, _, let from, let to, let choice):
            "Set \(d.name) to \(to.label) (\(choice.rawValue) mode\(from.map { ", was \($0)" } ?? ""))"
        }
    }

    private static func format(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime])
    }
}

/// Outcome of one executed rescue step.
public struct RescueOutcome: Hashable, Sendable {
    public let step: RescueStep
    /// nil when the step succeeded.
    public let error: String?
}

/// Gets the user back to a working desk [O§7.3]: revert the pending change, reconnect what
/// Keeplight disconnected, stop mirrors Keeplight created, then apply the known-good setup for
/// this display set, or else make the built-in display main and give each display its
/// default mode (flag 0x4), falling back to the largest CRISP mode, then the native mode.
public struct Rescue: Sendable {
    public let system: any DisplaySystem
    public let engine: TransactionEngine
    public let registry: DisconnectedRegistry
    public let mirrors: MirrorRegistry
    public let knownGood: KnownGoodStore
    public let journal: Journal
    private let clock: @Sendable () -> Date

    public init(system: any DisplaySystem, engine: TransactionEngine, registry: DisconnectedRegistry,
                mirrors: MirrorRegistry, knownGood: KnownGoodStore, journal: Journal,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.system = system
        self.engine = engine
        self.registry = registry
        self.mirrors = mirrors
        self.knownGood = knownGood
        self.journal = journal
        self.clock = clock
    }

    /// Live rescue over the standard support directory. Pass the app's engine so its pending
    /// change is reverted in-process.
    public static func standard(engine: TransactionEngine? = nil) -> Rescue {
        let system = LiveDisplaySystem()
        let directory = Keeplight.supportDirectory
        return Rescue(system: system,
                      engine: engine ?? TransactionEngine(applier: system, directory: directory, source: .rescue),
                      registry: .standard, mirrors: .standard, knownGood: .standard, journal: .standard)
    }

    /// The steps `run` would take now. Restore steps are predicted for the display set after
    /// reconnecting; `run` recomputes them once displays are back.
    public func plan() -> [RescueStep] {
        firstPhase() + restorePhase(reconnecting: registry.load(), stoppedMirrors: Set(mirrors.load().map(\.target.fp)))
    }

    /// True when no physical display is enabled (online); the app then rescues automatically.
    public func needsAutoRescue() -> Bool {
        !system.displays().contains { $0.isOnline && system.isPhysical($0.id) }
    }

    /// Executes the plan (unless `dryRun`) and journals each step with source `rescue`.
    @discardableResult
    public func run(dryRun: Bool = false) -> [RescueOutcome] {
        guard !dryRun else { return plan().map { RescueOutcome(step: $0, error: nil) } }
        let stoppedMirrors = Set(mirrors.load().map(\.target.fp))
        var outcomes = firstPhase().map(execute)
        // Mirrors in the registry that no longer exist are stale.
        let mirroring = Set(system.displays().filter(\.isMirrorTarget).map(\.fingerprint))
        for stale in mirrors.load() where !mirroring.contains(stale.target.fp) {
            try? mirrors.remove(targetFingerprint: stale.target.fp)
        }
        outcomes += restorePhase(reconnecting: [], stoppedMirrors: stoppedMirrors).map(execute)
        return outcomes
    }

    /// Auto-rescue: when no physical display is enabled, reconnect everything Keeplight disconnected.
    @discardableResult
    public func autoRescueIfNeeded() -> [RescueOutcome]? {
        guard needsAutoRescue() else { return nil }
        return registry.load().map { d in
            execute(.reconnect(d.ref, displayID: d.displayID), reason: "auto-rescue")
        }
    }

    // MARK: Planning

    private func firstPhase() -> [RescueStep] {
        var steps: [RescueStep] = []
        if let pending = engine.pending { steps.append(.revertPending(pending)) }
        for d in registry.load() { steps.append(.reconnect(d.ref, displayID: d.displayID)) }
        let online = system.displays()
        for created in mirrors.load() {
            if let d = online.first(where: { $0.fingerprint == created.target.fp && $0.isMirrorTarget }) {
                steps.append(.stopMirroring(d.ref, displayID: d.id))
            }
        }
        return steps
    }

    /// Known-good restore, else built-in main + default modes. `reconnecting` displays are
    /// counted in the display set (for planning before they are back). Mirrors Keeplight created
    /// (`stoppedMirrors`, target fingerprints) are not re-created from the known-good setup.
    private func restorePhase(reconnecting: [DisconnectedDisplay], stoppedMirrors: Set<String>) -> [RescueStep] {
        let online = system.displays()
        let current = system.snapshot()
        let signature = DisplaySnapshot.signature(online.map(\.fingerprint) + reconnecting.map(\.fingerprint))
        if var good = knownGood.snapshot(forSignature: signature) {
            // Rescue reconnects everything, so the known-good setup is applied with every display
            // on. Displays that were disconnected when it was saved have no mode or real position;
            // they are left where macOS puts them instead of being stacked at (0, 0).
            // A target of a mirror Keeplight created shares its source's origin, so it is left out
            // too rather than un-mirrored onto the same spot.
            good.displays.removeAll { e in
                e.modeNumber == nil || (e.mirrorSourceFingerprint != nil && stoppedMirrors.contains(e.fingerprint))
            }
            for i in good.displays.indices { good.displays[i].isEnabled = true }
            var predicted = current
            for d in reconnecting {
                if let i = predicted.displays.firstIndex(where: { $0.fingerprint == d.fingerprint }) {
                    predicted.displays[i].isEnabled = true
                }
            }
            let actions = DisplaySnapshot.restorePlan(from: predicted, to: good)
            return actions.isEmpty ? [] : [.applyKnownGood(good, actions: actions)]
        }
        var steps: [RescueStep] = []
        if let builtin = online.first(where: { $0.isBuiltin && !$0.isMirrorTarget }), !builtin.isMain {
            steps.append(.makeMain(builtin.ref, displayID: builtin.id))
        }
        for d in online where !d.isMirrorTarget {
            let modes = system.modes(for: d.id)
            guard let native = system.nativePixelSize(for: d.id),
                  case let (mode, choice)? = Self.fallbackMode(modes, native: native),
                  mode.modeNumber != d.currentMode?.modeNumber else { continue }
            steps.append(.setMode(d.ref, displayID: d.id, from: d.currentMode?.label, to: mode, choice: choice))
        }
        return steps
    }

    /// Default mode (flag 0x4; HiDPI, then highest refresh rate first), else the largest CRISP
    /// mode, else the native mode.
    public static func fallbackMode(_ modes: [DisplayMode],
                                    native: (width: Int, height: Int)) -> (DisplayMode, RescueStep.ModeChoice)? {
        let usable = modes.filter(\.isUsable)
        let best = { (candidates: [DisplayMode]) in
            candidates.max { a, b in
                (a.isHiDPI ? 1 : 0, a.width, a.refreshRate, a.depth, -Int(a.modeNumber))
                    < (b.isHiDPI ? 1 : 0, b.width, b.refreshRate, b.depth, -Int(b.modeNumber))
            }
        }
        if let m = best(usable.filter(\.isDefault)) { return (m, .systemDefault) }
        if let m = best(usable.filter { $0.sharpness(native: native) == .crisp }) { return (m, .largestCrisp) }
        if let m = best(usable.filter { $0.sharpness(native: native) == .native }) { return (m, .native) }
        return nil
    }

    // MARK: Execution

    private func execute(_ step: RescueStep) -> RescueOutcome {
        execute(step, reason: "rescue")
    }

    private func execute(_ step: RescueStep, reason: String) -> RescueOutcome {
        let started = ContinuousClock.now
        var entry: JournalEntry?
        var error: String?
        func record(_ kind: JournalEntry.Kind, _ display: DisplayRef?, before: String?, after: String?,
                    mechanism: String?, failure: Error?) {
            error = failure.map { String(describing: $0) }
            entry = JournalEntry(t: clock(), source: .rescue, display: display, kind: kind, before: before,
                                 after: after, mechanism: mechanism, result: failure == nil ? .applied : .failed,
                                 reason: reason, ms: TransactionEngine.ms(since: started), detail: error)
        }
        switch step {
        case .revertPending:
            do {
                let result = try engine.revert(reason: .rescue, source: .rescue)
                let failed = result.steps.filter { !$0.succeeded }
                error = failed.isEmpty ? nil : failed.map { "\($0.action): \($0.error ?? "")" }.joined(separator: "; ")
            } catch let e {
                error = String(describing: e)
            }
        case .reconnect(let d, let id):
            var failure: Error?
            do {
                try system.setEnabled(true, for: id, option: .forSession)
                try? registry.remove(fingerprint: d.fp)
            } catch let e { failure = e }
            record(.reconnect, d, before: "disconnected", after: "connected",
                    mechanism: TransactionKind.disconnect.mechanism, failure: failure)
        case .stopMirroring(let d, let id):
            var failure: Error?
            do {
                try system.unmirror(id, option: .permanently)
                try? mirrors.remove(targetFingerprint: d.fp)
            } catch let e { failure = e }
            record(.unmirror, d, before: "mirroring", after: "separate",
                    mechanism: TransactionKind.unmirror.mechanism, failure: failure)
        case .applyKnownGood(let good, _):
            let before = system.snapshot()
            let steps = system.restore(good, option: .permanently)
            let failed = steps.filter { !$0.succeeded }
            record(.restore, nil, before: "rescue snapshot \(before.signature)", after: "known-good \(good.signature)",
                    mechanism: "CGCompleteDisplayConfiguration",
                    failure: failed.isEmpty ? nil : DisplayError.refused(
                        failed.map { "\($0.action): \($0.error ?? "")" }.joined(separator: "; ")))
        case .makeMain(let d, let id):
            var failure: Error?
            do { try system.setMain(id, option: .permanently) } catch let e { failure = e }
            record(.main, d, before: nil, after: d.name, mechanism: TransactionKind.main.mechanism, failure: failure)
        case .setMode(let d, let id, let from, let to, _):
            var failure: Error?
            do { try system.setMode(to.modeNumber, for: id, option: .permanently) } catch let e { failure = e }
            record(.mode, d, before: from, after: to.label, mechanism: TransactionKind.mode.mechanism,
                    failure: failure)
        }
        if let entry { try? journal.append(entry) }
        return RescueOutcome(step: step, error: error)
    }
}
