import CoreGraphics
import Foundation
@testable import DisplayCore

/// A unique temporary directory, removed by `cleanup()`.
struct TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeplight-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path) }
}

/// A settable clock for deterministic timestamps.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { self.now } }
}

func dmode(_ n: Int32, _ w: Int, _ h: Int, hz: Double = 60, density: Double = 1,
          depth: Int = 8, flags: UInt32 = 0x1) -> DisplayMode {
    DisplayMode(modeNumber: n, width: w, height: h, refreshRate: hz, depth: depth, density: density, flags: flags)
}

func entry(_ fp: String, id: CGDirectDisplayID, name: String? = nil, mode: Int32? = 1, label: String? = nil,
           x: Int = 0, y: Int = 0, mirrorOf: String? = nil, enabled: Bool = true, main: Bool = false,
           builtin: Bool = false) -> DisplaySnapshot.Entry {
    DisplaySnapshot.Entry(fingerprint: fp, displayID: id, name: name ?? fp, modeNumber: mode, modeLabel: label,
                          origin: DisplayOrigin(x: x, y: y), mirrorSourceFingerprint: mirrorOf, isEnabled: enabled,
                          isMain: main, isBuiltin: builtin)
}

/// In-memory display system: `state` is the live configuration; every mutation is recorded.
final class FakeSystem: DisplaySystem, @unchecked Sendable {
    var state: DisplaySnapshot
    var modesByID: [CGDirectDisplayID: [DisplayMode]] = [:]
    var nativeByID: [CGDirectDisplayID: (width: Int, height: Int)] = [:]
    var physical: Set<CGDirectDisplayID> = []
    var calls: [String] = []
    var applyOptions: [CGConfigureOption] = []
    var restoreOptions: [CGConfigureOption] = []
    var restored: [DisplaySnapshot] = []
    var failNextApply = false

    init(_ displays: [DisplaySnapshot.Entry]) {
        state = DisplaySnapshot(displays: displays, takenAt: Date(timeIntervalSince1970: 0))
    }

    // DisplayApplier
    func snapshot() -> DisplaySnapshot { state }

    func restore(_ snapshot: DisplaySnapshot, option: CGConfigureOption) -> [RestoreStep] {
        restoreOptions.append(option)
        restored.append(snapshot)
        let plan = DisplaySnapshot.restorePlan(from: state, to: snapshot)
        for target in snapshot.displays {
            if let i = state.displays.firstIndex(where: { $0.fingerprint == target.fingerprint }) {
                state.displays[i] = target
            } else {
                state.displays.append(target)
            }
        }
        calls.append("restore")
        return plan.map { RestoreStep(action: $0) }
    }

    // DisplaySystem
    func displays() -> [DisplayInfo] {
        let idByFP = Dictionary(state.displays.map { ($0.fingerprint, $0.displayID) }, uniquingKeysWith: { a, _ in a })
        return state.displays.filter(\.isEnabled).map { e in
            DisplayInfo(id: e.displayID, name: e.name, vendorID: 1, productID: 1, serialNumber: e.displayID, uuid: nil,
                        isBuiltin: e.isBuiltin, isMain: e.isMain, isActive: true, isOnline: true,
                        mirrorSource: e.mirrorSourceFingerprint.flatMap { idByFP[$0] },
                        bounds: CGRect(x: e.origin.x, y: e.origin.y, width: 100, height: 100), rotation: 0,
                        currentMode: modesByID[e.displayID]?.first { $0.modeNumber == e.modeNumber },
                        fingerprint: e.fingerprint)
        }
    }

    func modes(for id: CGDirectDisplayID) -> [DisplayMode] { modesByID[id] ?? [] }
    func nativePixelSize(for id: CGDirectDisplayID) -> (width: Int, height: Int)? { nativeByID[id] }
    func isPhysical(_ id: CGDirectDisplayID) -> Bool { physical.contains(id) }

    func setEnabled(_ enabled: Bool, for id: CGDirectDisplayID, option: CGConfigureOption) throws {
        calls.append("setEnabled(\(enabled), \(id))")
        try update(id) { $0.isEnabled = enabled }
    }

    func setMain(_ id: CGDirectDisplayID, option: CGConfigureOption) throws {
        calls.append("setMain(\(id))")
        for i in state.displays.indices { state.displays[i].isMain = state.displays[i].displayID == id }
    }

    func setMode(_ modeNumber: Int32, for id: CGDirectDisplayID, option: CGConfigureOption) throws {
        calls.append("setMode(\(modeNumber), \(id))")
        try update(id) { $0.modeNumber = modeNumber }
    }

    func unmirror(_ id: CGDirectDisplayID, option: CGConfigureOption) throws {
        calls.append("unmirror(\(id))")
        try update(id) { $0.mirrorSourceFingerprint = nil }
    }

    /// A transaction body: records the option and runs `change` on the state.
    func apply(_ change: @escaping @Sendable (inout DisplaySnapshot) -> Void) -> TransactionEngine.Apply {
        { option in
            self.applyOptions.append(option)
            if self.failNextApply {
                self.failNextApply = false
                throw DisplayError.refused("fake failure")
            }
            change(&self.state)
        }
    }

    private func update(_ id: CGDirectDisplayID, _ body: (inout DisplaySnapshot.Entry) -> Void) throws {
        guard let i = state.displays.firstIndex(where: { $0.displayID == id }) else {
            throw DisplayError.displayNotFound("id \(id)")
        }
        body(&state.displays[i])
    }
}

extension DisplaySnapshot {
    mutating func set(_ fp: String, _ body: (inout Entry) -> Void) {
        if let i = displays.firstIndex(where: { $0.fingerprint == fp }) { body(&displays[i]) }
    }
}
