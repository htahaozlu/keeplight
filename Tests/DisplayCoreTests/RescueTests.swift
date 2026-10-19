import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore

private let builtin = DisplayRef(name: "Built-in", fp: "APP:A059:1")
private let desk = DisplayRef(name: "Desk right", fp: "DEL:A0F3:SN")
private let projector = DisplayRef(name: "Projector", fp: "EPS:0001:7")

private struct World {
    let dir = TempDir()
    let clock = TestClock()
    let system: FakeSystem

    init(_ displays: [DisplaySnapshot.Entry]) {
        system = FakeSystem(displays)
        system.physical = [1, 3, 4]
    }

    var registry: DisconnectedRegistry { DisconnectedRegistry(directory: dir.url) }
    var mirrors: MirrorRegistry { MirrorRegistry(directory: dir.url) }
    var knownGood: KnownGoodStore { KnownGoodStore(directory: dir.url) }
    var journal: Journal { Journal(directory: dir.url, clock: clock.function) }

    func engine() -> TransactionEngine {
        TransactionEngine(applier: system, directory: dir.url, clock: clock.function)
    }

    func rescue(_ engine: TransactionEngine? = nil) -> Rescue {
        Rescue(system: system, engine: engine ?? self.engine(), registry: registry, mirrors: mirrors,
               knownGood: knownGood, journal: journal, clock: clock.function)
    }
}

private func kinds(_ steps: [RescueStep]) -> [String] {
    steps.map { step in
        switch step {
        case .revertPending: "revertPending"
        case .reconnect(let d, _): "reconnect \(d.name)"
        case .stopMirroring(let d, _): "stopMirroring \(d.name)"
        case .applyKnownGood: "applyKnownGood"
        case .makeMain(let d, _): "makeMain \(d.name)"
        case .setMode(let d, _, _, let to, let choice): "setMode \(d.name) \(to.modeNumber) \(choice.rawValue)"
        }
    }
}

@Test func rescuePlanOrdersStepsAndUsesKnownGood() throws {
    let world = World([
        entry(builtin.fp, id: 1, name: "Built-in", mode: 54, main: true, builtin: true),
        entry(desk.fp, id: 3, name: "Desk right", mode: 90, mirrorOf: builtin.fp),
        entry(projector.fp, id: 4, name: "Projector", mode: 7, enabled: false),
    ])
    defer { world.dir.cleanup() }
    // The kept setup for these three displays: side by side, desk main.
    try world.knownGood.save(DisplaySnapshot(displays: [
        entry(builtin.fp, id: 1, name: "Built-in", mode: 54, x: -1512, builtin: true),
        entry(desk.fp, id: 3, name: "Desk right", mode: 90, main: true),
        entry(projector.fp, id: 4, name: "Projector", mode: 7, x: 2560, enabled: false),
    ]))
    try world.registry.add(DisconnectedDisplay(fingerprint: projector.fp, displayID: 4, name: "Projector"))
    try world.mirrors.add(CreatedMirror(target: desk, sourceFingerprint: builtin.fp))
    let engine = world.engine()
    try engine.begin(kind: .mode, display: builtin, summary: "",
                     apply: world.system.apply { $0.set(builtin.fp) { $0.modeNumber = 55 } })

    let rescue = world.rescue(engine)
    let plan = rescue.plan()
    #expect(kinds(plan) == ["revertPending", "reconnect Projector", "stopMirroring Desk right", "applyKnownGood"])
    if case .applyKnownGood(let good, let actions) = plan.last {
        #expect(good.displays.allSatisfy { $0.isEnabled })  // rescue never re-disconnects
        #expect(actions.contains { if case .arrange = $0 { true } else { false } })
    }

    // Dry run touches nothing.
    let dry = rescue.run(dryRun: true)
    #expect(dry.count == plan.count && world.system.calls.isEmpty)
    #expect(world.journal.entries().isEmpty)

    let outcomes = rescue.run()
    #expect(outcomes.allSatisfy { $0.error == nil })
    #expect(kinds(outcomes.map(\.step)) == kinds(plan))
    #expect(world.system.calls.prefix(3) == ["restore", "setEnabled(true, 4)", "unmirror(3)"])
    #expect(engine.pending == nil && !world.dir.exists("pending.json"))
    #expect(world.registry.load().isEmpty && world.mirrors.load().isEmpty)
    let state = world.system.state
    #expect(state.entry(for: desk.fp)?.isMain == true)
    #expect(state.entry(for: builtin.fp)?.origin == DisplayOrigin(x: -1512, y: 0))
    #expect(state.entry(for: builtin.fp)?.modeNumber == 54)  // pending change reverted
    #expect(state.displays.allSatisfy { $0.isEnabled })

    let entries = world.journal.entries()
    #expect(entries.map(\.kind) == [.mode, .reconnect, .unmirror, .restore])
    #expect(entries.allSatisfy { $0.source == .rescue && $0.reason == "rescue" })
    #expect(entries.allSatisfy { $0.result != .failed })

    // Afterwards there is nothing left to do.
    #expect(rescue.plan().isEmpty)
}

@Test func rescueFallbackWithoutKnownGood() {
    let world = World([
        entry(desk.fp, id: 3, name: "Desk right", mode: 92, main: true),
        entry(builtin.fp, id: 1, name: "Built-in", mode: 55, x: -1512, builtin: true),
        entry(projector.fp, id: 4, name: "Projector", mode: 8, x: 2560),
    ])
    defer { world.dir.cleanup() }
    world.system.modesByID = [
        1: [dmode(54, 1512, 982, hz: 120, density: 2, flags: 0x0200_0007), dmode(55, 1800, 1169, hz: 120, density: 2)],
        3: [dmode(90, 1920, 1080, density: 2, flags: 0x0200_0001), dmode(92, 2560, 1440, density: 2),
            dmode(93, 3840, 2160, flags: 0x0200_0001)],
        4: [dmode(7, 1920, 1080), dmode(8, 1280, 720)],
    ]
    world.system.nativeByID = [1: (3024, 1964), 3: (3840, 2160), 4: (1920, 1080)]
    let rescue = world.rescue()
    #expect(kinds(rescue.plan()) == [
        "makeMain Built-in",
        "setMode Desk right 90 crisp",
        "setMode Built-in 54 default",
        "setMode Projector 7 native",
    ])
    let outcomes = rescue.run()
    #expect(outcomes.count == 4 && outcomes.allSatisfy { $0.error == nil })
    #expect(world.system.state.entry(for: builtin.fp)?.isMain == true)
    #expect(world.system.state.entry(for: desk.fp)?.modeNumber == 90)
    #expect(world.journal.entries().map(\.kind) == [.main, .mode, .mode, .mode])
    #expect(rescue.plan().isEmpty)
}

@Test func fallbackModePreference() {
    let native = (width: 3840, height: 2160)
    let withDefault = [dmode(1, 1920, 1080, density: 2), dmode(2, 2560, 1440, density: 2, flags: 0x5)]
    #expect(Rescue.fallbackMode(withDefault, native: native)?.1 == .systemDefault)
    #expect(Rescue.fallbackMode(withDefault, native: native)?.0.modeNumber == 2)
    let crisp = [dmode(1, 1920, 1080, hz: 30, density: 2), dmode(2, 1920, 1080, density: 2), dmode(3, 3840, 2160)]
    #expect(Rescue.fallbackMode(crisp, native: native)?.0.modeNumber == 2)  // highest refresh rate
    #expect(Rescue.fallbackMode([dmode(3, 3840, 2160), dmode(4, 1920, 1080)], native: native)?.1 == .native)
    #expect(Rescue.fallbackMode([dmode(4, 1920, 1080)], native: native) == nil)
}

@Test func autoRescueWhenNoPhysicalDisplayIsEnabled() throws {
    let world = World([
        entry(builtin.fp, id: 1, name: "Built-in", enabled: false, builtin: true),
        entry("SIDECAR", id: 9, name: "iPad", main: true),
    ])
    defer { world.dir.cleanup() }
    try world.registry.add(DisconnectedDisplay(fingerprint: builtin.fp, displayID: 1, name: "Built-in"))
    let rescue = world.rescue()
    #expect(rescue.needsAutoRescue())
    let outcomes = try #require(rescue.autoRescueIfNeeded())
    #expect(outcomes.count == 1 && outcomes[0].error == nil)
    #expect(world.system.state.entry(for: builtin.fp)?.isEnabled == true)
    #expect(!rescue.needsAutoRescue())
    #expect(rescue.autoRescueIfNeeded() == nil)
    #expect(world.journal.entries().first?.reason == "auto-rescue")
}

@Test func rescueKnownGoodSkipsUnplacedDisplaysAndKeeplightMirrors() throws {
    let world = World([
        entry(builtin.fp, id: 1, name: "Built-in", mode: 54, main: true, builtin: true),
        entry(desk.fp, id: 3, name: "Desk right", mode: 90, mirrorOf: builtin.fp),
        entry(projector.fp, id: 4, name: "Projector", mode: 7, x: 3000),
    ])
    defer { world.dir.cleanup() }
    // Saved while Keeplight's mirror was on and the projector was disconnected.
    try world.knownGood.save(DisplaySnapshot(displays: [
        entry(builtin.fp, id: 1, name: "Built-in", mode: 54, main: true, builtin: true),
        entry(desk.fp, id: 3, name: "Desk right", mode: 90, mirrorOf: builtin.fp),
        entry(projector.fp, id: 4, name: "Projector", mode: nil, enabled: false),
    ]))
    try world.mirrors.add(CreatedMirror(target: desk, sourceFingerprint: builtin.fp))
    let outcomes = world.rescue().run()
    #expect(outcomes.allSatisfy { $0.error == nil })
    let state = world.system.state
    #expect(state.entry(for: desk.fp)?.mirrorSourceFingerprint == nil)               // not mirrored again
    #expect(state.entry(for: projector.fp)?.origin == DisplayOrigin(x: 3000, y: 0))   // not stacked at (0, 0)
}
