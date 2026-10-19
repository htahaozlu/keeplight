import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore

/// Records gamma writes; one 3-entry identity table per display.
final class FakeGamma: GammaTables, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var current: [CGDirectDisplayID: GammaTable] = [:]
    static let identity = GammaTable(red: [0, 0.5, 1], green: [0, 0.5, 1], blue: [0, 0.5, 1])

    var events: [String] { lock.withLock { log } }
    func table(_ id: CGDirectDisplayID) -> GammaTable { lock.withLock { current[id] ?? Self.identity } }

    func read(_ id: CGDirectDisplayID) -> GammaTable? { lock.withLock { log.append("read"); return current[id] ?? Self.identity } }
    func write(_ table: GammaTable, to id: CGDirectDisplayID) -> Bool {
        lock.withLock {
            log.append("gamma \(String(format: "%.2f", table.red.last ?? 0))")
            current[id] = table
        }
        return true
    }
    func note(_ text: String) { lock.withLock { log.append(text) } }
}

/// A DDC control that records its writes into the shared log.
struct LoggedDDC: BrightnessControl {
    let displayID: CGDirectDisplayID = 3
    var backend: BrightnessBackend { .ddc }
    let gamma: FakeGamma
    let level: Box

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Double
        init(_ value: Double) { stored = value }
        var value: Double {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    func brightness() throws -> Double { level.value }
    func setBrightness(_ value: Double) throws {
        level.value = value
        gamma.note("ddc \(Int((value * 100).rounded()))")
    }
}

@Suite("Dimming below the monitor's minimum")
struct DimmingTests {
    @Test func theCurveSplitsAtTheHandoverOnTheKeyGrid() {
        #expect(DimmingCurve.handover == 3.0 / 16)
        #expect(DimmingCurve.split(1) == (1, 1))
        #expect(DimmingCurve.split(DimmingCurve.handover) == (0, 1))
        #expect(DimmingCurve.split(0) == (0, DimmingCurve.darkest))
        let mid = DimmingCurve.split(DimmingCurve.handover / 2)
        #expect(mid.hardware == 0 && abs(mid.gain - (DimmingCurve.darkest + (1 - DimmingCurve.darkest) / 2)) < 1e-9)
        // Round trip everywhere on the 16-step key grid.
        for step in 0...16 {
            let v = Double(step) / 16
            let (h, g) = DimmingCurve.split(v)
            #expect(abs(DimmingCurve.combine(hardware: h, gain: g) - v) < 1e-9)
        }
    }

    @Test func aMonitorAboveZeroWinsOverAStaleGain() {
        #expect(DimmingCurve.combine(hardware: 0.5, gain: 0.4) == DimmingCurve.fromHardware(0.5))
        #expect(DimmingCurve.fromHardware(0) == DimmingCurve.handover)
        #expect(DimmingCurve.fromHardware(1) == 1)
    }

    @Test func theDimmerKeepsTheOriginalTableAndPutsItBack() {
        let gamma = FakeGamma()
        let dimmer = SoftwareDimmer(tables: gamma)
        dimmer.setGain(0.5, for: 3)
        dimmer.setGain(0.4, for: 3)
        #expect(gamma.events.filter { $0 == "read" }.count == 1)  // captured once
        #expect(gamma.table(3) == FakeGamma.identity.scaled(by: 0.4))
        #expect(dimmer.gain(for: 3) == 0.4)
        dimmer.setGain(1, for: 3)
        #expect(gamma.table(3) == FakeGamma.identity)
        #expect(dimmer.gain(for: 3) == 1)
        dimmer.setGain(1, for: 3)
        #expect(gamma.events.count == 4)  // read, 0.50, 0.40, restore; nothing at gain 1 again
        dimmer.setGain(0.3, for: 3)
        dimmer.resetAll()
        #expect(gamma.table(3) == FakeGamma.identity && dimmer.gain(for: 3) == 1)
    }

    @Test func reapplyWritesTheDimmedTableAgain() {
        let gamma = FakeGamma()
        let dimmer = SoftwareDimmer(tables: gamma)
        dimmer.setGain(0.6, for: 3)
        let writes = gamma.events.count
        dimmer.reapply()
        #expect(gamma.events.count == writes + 1)
        #expect(gamma.table(3) == FakeGamma.identity.scaled(by: 0.6))
    }

    @Test func goingDarkerLowersTheBacklightThenTheGammaAndNeverRepeatsDDCZero() throws {
        let gamma = FakeGamma()
        let control = DimmingBrightness(base: LoggedDDC(gamma: gamma, level: .init(0.5)), dimmer: SoftwareDimmer(tables: gamma))
        try control.setBrightness(DimmingCurve.handover + (1 - DimmingCurve.handover) * 0.2)  // DDC 20
        try control.setBrightness(2.0 / 16)
        try control.setBrightness(1.0 / 16)
        try control.setBrightness(0)
        let ddc = gamma.events.filter { $0.hasPrefix("ddc") }
        #expect(ddc == ["ddc 20", "ddc 0"])
        // 0 % is black, like a Mac screen at its lowest.
        #expect(gamma.events.last == "gamma 0.00")
        #expect(abs(try control.brightness() - 0) < 1e-9)
        #expect(control.mechanism == "DDC VCP 0x10 + gamma")
    }

    @Test func goingBrighterLiftsTheGammaBeforeTheBacklight() throws {
        let gamma = FakeGamma()
        let control = DimmingBrightness(base: LoggedDDC(gamma: gamma, level: .init(0)), dimmer: SoftwareDimmer(tables: gamma))
        try control.setBrightness(0)
        try control.setBrightness(1)
        let tail = Array(gamma.events.suffix(2))
        #expect(tail == ["gamma 1.00", "ddc 100"])
        #expect(try control.brightness() == 1)
    }

    @Test func afterReapplyTheNextLevelIsSentEvenIfUnchanged() throws {
        let gamma = FakeGamma()
        let dimmer = SoftwareDimmer(tables: gamma)
        let control = DimmingBrightness(base: LoggedDDC(gamma: gamma, level: .init(0)), dimmer: dimmer)
        try control.setBrightness(1.0 / 16)
        dimmer.reapply()  // wake: the monitor may have reset itself
        try control.setBrightness(1.0 / 16)
        #expect(gamma.events.filter { $0 == "ddc 0" }.count == 2)
    }

    @Test func zeroIsBlackAndWakeLiftsABlackScreenToTheFirstStep() {
        #expect(DimmingCurve.darkest == 0)
        #expect(DimmingCurve.split(0).gain == 0)
        let gamma = FakeGamma()
        let dimmer = SoftwareDimmer(tables: gamma)
        dimmer.setGain(0, for: 3)
        #expect(gamma.table(3) == FakeGamma.identity.scaled(by: 0))
        dimmer.reapply(liftingBelow: DimmingCurve.wakeGain)
        #expect(dimmer.gain(for: 3) == DimmingCurve.wakeGain)
        #expect(gamma.table(3) == FakeGamma.identity.scaled(by: DimmingCurve.wakeGain))
        // The lifted gain is one key step above black on the app's range.
        #expect(abs(DimmingCurve.combine(hardware: 0, gain: DimmingCurve.wakeGain) - 1.0 / 16) < 1e-9)
        // A reconfiguration (no lift) keeps the user's choice.
        dimmer.setGain(0, for: 3)
        dimmer.reapply()
        #expect(dimmer.gain(for: 3) == 0)
    }
}
