#if DEBUG
import AppKit
import DisplayCore
@testable import KeeplightUI

/// Builds an `AppModel` on fakes, in read-only (debug) mode, with a synthetic desk.
@MainActor
enum Models {
    /// Fresh, empty temporary directory per run; checked empty at the end.
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeplight-render-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var shells: [FakeShell] = []

    /// `flags.debug` makes every model action read-only on top of the fakes: transactions,
    /// brightness writes, undo, rescue, reconnect, login item and the key tap all return early.
    static func make(_ desk: Desk.Kind, disconnected: [DisconnectedDisplay] = []) -> AppModel {
        let fakes = Desk.displays(desk)
        let system = FakeDisplaySystem(fakes)
        let services = FakeServices.make(system: system, directory: directory)
        let engine = TransactionEngine(applier: system, directory: directory, source: .panel)
        let flags = LaunchFlags(debug: true, safeStart: false, debugStates: [:])
        let model = AppModel(flags: flags, engine: engine, recovered: nil, services: services)
        let shell = FakeShell()
        shells.append(shell)
        model.shell = shell

        // What `refresh()` would build, from the fake system, without touching CoreGraphics.
        model.fakeDisplays = true
        let shown = system.displays().filter { $0.isActive || ($0.isOnline && $0.isMirrorTarget) }
        let order = DeskLayout.order(shown.map { (id: $0.id, bounds: $0.bounds) })
        model.items = order.enumerated().compactMap { offset, id in
            guard let info = shown.first(where: { $0.id == id }) else { return nil }
            return DisplayItem(info: info, index: offset + 1, modes: system.modes(for: id),
                               native: system.nativePixelSize(for: id).map(PixelSize.init), isPhysical: true,
                               isNew: false)
        }
        model.knownIDs = Set(model.items.map(\.id))
        for fake in fakes {
            if let backend = fake.backend {
                model.brightness[fake.info.id] = .available(
                    control: FakeBrightness(displayID: fake.info.id, backend: backend, level: fake.level),
                    value: fake.level, readMs: backend == .ddc ? 112 : 3)
            } else if model.items.contains(where: { $0.id == fake.info.id }) {
                model.brightness[fake.info.id] = .unavailable
            }
            model.prefs.knownDisplays[fake.info.fingerprint] = fake.info.name
        }
        model.disconnected = disconnected
        model.debugJournal = journal(model)
        // A 14" MacBook Pro's visible height minus the panel's 80 pt allowance.
        model.panelMaxHeight = 869
        model.isPanelOpen = true
        return model
    }

    /// A believable afternoon of changes (Settings › Journal).
    static func journal(_ model: AppModel) -> [JournalEntry] {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let dell = DisplayRef(name: "DELL U2723QE", fp: "RENDER:10AC:A0F3:DELL")
        let lg = DisplayRef(name: "LG HDR 4K", fp: "RENDER:1E6D:5B9C:LG")
        func entry(_ minutes: Double, _ kind: JournalEntry.Kind, _ before: String, _ after: String,
                   source: JournalEntry.Source = .panel, result: JournalEntry.Outcome = .applied,
                   display: DisplayRef = dell, reason: String? = nil, mechanism: String? = nil) -> JournalEntry {
            JournalEntry(id: "render-\(Int(minutes))", t: now.addingTimeInterval(-minutes * 60), source: source,
                         display: display, kind: kind, before: before, after: after, mechanism: mechanism,
                         result: result, reason: reason)
        }
        return [
            entry(190, .brightness, "100%", "40%", source: .wake, result: .restored, mechanism: "DDC VCP 0x10"),
            entry(120, .mode, "2560x1440@60 hidpi", "3008x1692@60 hidpi", result: .reverted, reason: "timeout"),
            entry(45, .brightness, "40%", "55%", mechanism: "DDC VCP 0x10"),
            entry(30, .main, Desk.builtinName, "DELL U2723QE", result: .kept),
            entry(12, .mode, "1920x1080@60 hidpi", "2560x1440@60 hidpi", result: .kept),
            entry(9, .ddc, "40", "55", source: .cli, mechanism: "0x10"),
            entry(4, .disconnect, "connected", "disconnected", result: .kept, display: lg),
            entry(2, .reconnect, "disconnected", "connected", source: .cli, display: lg),
        ]
    }
}
#endif
